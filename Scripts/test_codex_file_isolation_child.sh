#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-file-child.XXXXXX")"
trap 'rm -rf "$PROOF_DIR"' EXIT

# Compile the actual policy and detector without DEBUG. Only unrelated link dependencies are stubbed;
# this is policy/child proof, not a release build of the entire app or credential store.
cat > "$PROOF_DIR/Proof.swift" <<'SWIFT'
import Foundation

enum CodexOAuthCredentialsError: Error { case notFound }
enum KeychainAccessGate {
    static let disableAccessEnvironmentKey = "CODEXBAR_DISABLE_KEYCHAIN_ACCESS"
    static var isDisabled: Bool { fatalError("The file policy must not consult Keychain state") }
}

@main
struct Proof {
    static func main() throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[2])
        let childRoot = root.appendingPathComponent("child")
        let childFile = childRoot.appendingPathComponent("auth.json")
        let parentFile = root.appendingPathComponent("parent-auth.json")
        if args[1] == "launch" {
            try FileManager.default.createDirectory(at: childRoot, withIntermediateDirectories: true)
            try Data("synthetic-child".utf8).write(to: childFile)
            try Data("synthetic-parent".utf8).write(to: parentFile)
            let inherited = [CodexCredentialFileAccess.isolationEnvironmentKey: "1",
                             "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                             "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1",
                             "CODEX_HOME": root.path]
            for mode in ["deny", "fixture", "production"] {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: args[0])
                child.arguments = [mode, root.path]
                if mode == "fixture" {
                    let parentScope = CodexCredentialFileAccess.FixtureScope(files: [parentFile])
                    let base = try parentScope.childEnvironment(base: inherited)
                    child.environment = try CodexCredentialFileAccess.FixtureScope(roots: [childRoot])
                        .childEnvironment(base: base)
                } else {
                    child.environment = mode == "production" ? [:] : inherited
                }
                try child.run()
                child.waitUntilExit()
                precondition(child.terminationStatus == 0, "Child policy proof failed")
            }
            print("Optimized policy child: deny, scoped fixture, parent-grant replacement, and pure non-test decision passed")
            return
        }
        if args[1] == "production" {
            precondition(!CodexCredentialFileAccess.isTestContext)
            precondition(CodexCredentialFileAccess.permits(URL(fileURLWithPath: "/fictitious/auth.json")))
            return
        }
        let allowed = args[1] != "deny"
        precondition(CodexCredentialFileAccess.isTestContext)
        precondition(CodexCredentialFileAccess.fileExists(at: childFile) == allowed)
        if allowed {
            let data = try CodexCredentialFileAccess.read(at: childFile)
            precondition(data == Data("synthetic-child".utf8))
        } else {
            do {
                _ = try CodexCredentialFileAccess.read(at: childFile)
                fatalError("An existing but unregistered fixture was read")
            } catch CodexOAuthCredentialsError.notFound {}
        }
        precondition(!CodexCredentialFileAccess.permits(parentFile))
    }
}
SWIFT

swiftc -O -parse-as-library \
  "$ROOT_DIR/Sources/CodexBarCore/CodexCredentialFileAccess.swift" \
  "$ROOT_DIR/Sources/CodexBarCore/KeychainSecurity.swift" \
  "$PROOF_DIR/Proof.swift" -o "$PROOF_DIR/codex-file-child"
"$PROOF_DIR/codex-file-child" launch "$PROOF_DIR/fixtures"
