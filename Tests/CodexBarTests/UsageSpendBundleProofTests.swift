import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageSpendBundleProofTests {
    @Test
    func `proof mode stays inert without an output directory`() {
        #expect(UsageSpendBundleProof.requestDirectory(environment: [:]) == nil)
        #expect(UsageSpendBundleProof.requestDirectory(environment: [
            "CODEXBAR_SPEND_BUNDLE_PROOF_DIR": "   ",
        ]) == nil)
    }

    @Test
    func `proof mode trims its output directory`() {
        #expect(UsageSpendBundleProof.requestDirectory(environment: [
            "CODEXBAR_SPEND_BUNDLE_PROOF_DIR": " /tmp/proof ",
        ]) == "/tmp/proof")
    }

    @Test
    func `proof mode requires every isolation boundary`() {
        #expect(UsageSpendBundleProof.isolationFailure(environment: [:]) != nil)
        let proofRoot = FileManager.default.temporaryDirectory
            .appending(path: "codexbar-spend-proof-\(UUID().uuidString)", directoryHint: .isDirectory)
        var environment = self.isolatedEnvironment(proofRoot: proofRoot)
        #expect(UsageSpendBundleProof.isolationFailure(environment: environment) == nil)
        environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] = "0"
        #expect(UsageSpendBundleProof.isolationFailure(environment: environment)?.contains("expected 1") == true)
    }

    @Test
    func `proof mode rejects profile paths outside its temporary root`() {
        let proofRoot = FileManager.default.temporaryDirectory
            .appending(path: "codexbar-spend-proof-\(UUID().uuidString)", directoryHint: .isDirectory)
        var environment = self.isolatedEnvironment(proofRoot: proofRoot)
        environment["CFFIXED_USER_HOME"] = NSHomeDirectory()
        environment["HOME"] = NSHomeDirectory()

        #expect(UsageSpendBundleProof.isolationFailure(environment: environment)?.contains("inside the proof root") ==
            true)
    }

    @Test
    func `proof mode rejects mismatched fixed and process homes`() {
        let proofRoot = FileManager.default.temporaryDirectory
            .appending(path: "codexbar-spend-proof-\(UUID().uuidString)", directoryHint: .isDirectory)
        var environment = self.isolatedEnvironment(proofRoot: proofRoot)
        environment["HOME"] = proofRoot.appending(path: "different-home", directoryHint: .isDirectory).path

        #expect(UsageSpendBundleProof.isolationFailure(environment: environment)?
            .contains("must resolve to the same") ==
            true)
    }

    @Test
    func `proof mode rejects a root outside the system temporary directory`() {
        let proofRoot = URL(fileURLWithPath: "/Users/example/codexbar-spend-proof", isDirectory: true)
        let environment = self.isolatedEnvironment(proofRoot: proofRoot)

        #expect(UsageSpendBundleProof.isolationFailure(environment: environment)?.contains(
            "system temporary directory") == true)
    }

    @Test
    func `proof mode ignores a hostile temporary directory override`() {
        let proofRoot = URL(fileURLWithPath: "/Users/example/real-profile", isDirectory: true)
        var environment = self.isolatedEnvironment(proofRoot: proofRoot)
        environment["TMPDIR"] = "/"

        #expect(UsageSpendBundleProof.trustedSystemTemporaryDirectory() != "/")
        #expect(UsageSpendBundleProof.isolationFailure(environment: environment)?.contains(
            "system temporary directory") == true)
    }

    private func isolatedEnvironment(proofRoot: URL) -> [String: String] {
        [
            "CODEXBAR_SPEND_BUNDLE_PROOF_DIR": proofRoot.path,
            "CFFIXED_USER_HOME": proofRoot.appending(path: "home", directoryHint: .isDirectory).path,
            "HOME": proofRoot.appending(path: "home", directoryHint: .isDirectory).path,
            "CODEX_HOME": proofRoot.appending(path: "codex", directoryHint: .isDirectory).path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            CodexCredentialFileAccess.isolationEnvironmentKey: "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
            "SWIFT_TESTING": "1",
            "SWIFT_TESTING_ENABLED": "1",
        ]
    }
}
