#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

struct CodexRemoteLogManifest: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let path: String
        let size: Int64
        let revision: String
        let sha256: String
    }

    static let rootNames = ["sessions", "archived_sessions"]
    let home: String
    let roots: [String: String]
    let directories: Set<String>
    let files: [String: Entry]

    init(_ output: String, limits: CodexRemoteLogMirror.Limits) throws {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, fields.removeLast().isEmpty,
              fields.removeFirst() == "CODEX_LOGS_V1"
        else { throw CodexRemoteLogError.invalidManifest }
        let home = fields.removeFirst()
        guard home.hasPrefix("/"), CodexRemoteLogSource.validHome(home) else {
            throw CodexRemoteLogError.unsafePath
        }
        var roots: [String: String] = [:]
        var directories: Set<String> = []
        var files: [String: Entry] = [:]
        var spelling: [String: String] = [:]
        var bytes: Int64 = 0
        var index = 0
        var ended = false
        func take(_ count: Int) throws -> [String] {
            guard index + count <= fields.count else { throw CodexRemoteLogError.invalidManifest }
            let result = Array(fields[index..<(index + count)])
            index += count
            return result
        }
        func acceptPath(_ path: String) throws {
            guard Self.validPath(path) else { throw CodexRemoteLogError.unsafePath }
            let pieces = path.split(separator: "/")
            for end in 1...pieces.count {
                let prefix = pieces.prefix(end).joined(separator: "/")
                let folded = prefix.lowercased()
                if let previous = spelling[folded], previous != prefix {
                    throw CodexRemoteLogError.unsafePath
                }
                spelling[folded] = prefix
            }
        }
        while index < fields.count {
            let tag = try take(1)[0]
            switch tag {
            case "R":
                let values = try take(2)
                guard Self.rootNames.contains(values[0]), roots[values[0]] == nil else {
                    throw CodexRemoteLogError.invalidManifest
                }
                guard ["present", "missing"].contains(values[1]) else {
                    throw CodexRemoteLogError.inaccessibleRoot
                }
                roots[values[0]] = values[1]
            case "D":
                let path = try take(1)[0]
                try acceptPath(path)
                try Self.checkDirectoryCount(directories.count, limits: limits)
                guard directories.insert(path).inserted else { throw CodexRemoteLogError.invalidManifest }
            case "F":
                let values = try take(4)
                let path = values[0]
                try acceptPath(path)
                guard path.hasSuffix(".jsonl"), !Self.rootNames.contains(path), files[path] == nil,
                      let size = Int64(values[1]), size >= 0,
                      !values[2].isEmpty, values[2].utf8.count <= 256,
                      values[3].utf8.count == 64,
                      values[3].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw CodexRemoteLogError.invalidManifest }
                guard size <= limits.fileBytes, size <= limits.totalBytes - bytes,
                      files.count < limits.fileCount
                else { throw CodexRemoteLogError.budgetExceeded }
                bytes += size
                files[path] = Entry(path: path, size: size, revision: values[2], sha256: values[3])
            case "END":
                guard index == fields.count else { throw CodexRemoteLogError.invalidManifest }
                ended = true
            default: throw CodexRemoteLogError.invalidManifest
            }
        }
        guard ended, roots.count == 2 else { throw CodexRemoteLogError.invalidManifest }
        for path in directories.union(files.keys) {
            guard let root = path.split(separator: "/").first, roots[String(root)] == "present" else {
                throw CodexRemoteLogError.invalidManifest
            }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard directories.contains(parent), files[parent] == nil else {
                    throw CodexRemoteLogError.invalidManifest
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard files.keys.allSatisfy({ !directories.contains($0) }) else {
            throw CodexRemoteLogError.invalidManifest
        }
        self.home = home
        self.roots = roots
        self.directories = directories
        self.files = files
    }

    static func validPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 1024 && components.count <= 32
            && components.first.map { self.rootNames.contains(String($0)) } == true
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
                    && $0.utf8.allSatisfy { CodexRemoteLogSource.isNameByte($0) || $0 == 46 }
            }
    }

    private static func checkDirectoryCount(_ count: Int, limits: CodexRemoteLogMirror.Limits) throws {
        guard count < limits.fileCount + 2 else { throw CodexRemoteLogError.budgetExceeded }
    }

    /// Uses Linux coreutils only. No files are created on the server.
    static func command(home: String, limits: CodexRemoteLogMirror.Limits) -> String {
        let assignment = home.hasPrefix("~/")
            ? "home=\"$HOME\"/" + Self.quote(String(home.dropFirst(2)))
            : "home=" + Self.quote(home)
        let script = #"""
        set -eu
        export LC_ALL=C
        for tool in find stat sha256sum rsync; do command -v "$tool" >/dev/null || exit 42; done
        \#(assignment)
        case "$home" in /*) ;; *) exit 44;; esac
        ancestor="$home"
        while [ "$ancestor" != / ]; do
          [ ! -L "$ancestor" ] || exit 44
          ancestor=${ancestor%/*}; [ -n "$ancestor" ] || ancestor=/
        done
        [ -d "$home" ] && [ -r "$home" ] && [ -x "$home" ] || exit 43
        exec 3>&1
        printf 'CODEX_LOGS_V1\000%s\000' "$home"
        for root in sessions archived_sessions; do
          directory="$home/$root"
          [ ! -L "$directory" ] || exit 44
          if [ ! -e "$directory" ]; then printf 'R\000%s\000missing\000' "$root"; continue; fi
          [ -d "$directory" ] && [ -r "$directory" ] && [ -x "$directory" ] || exit 43
          printf 'R\000%s\000present\000' "$root"
          # find -exec ... + does not preserve its child's exit status. Keep manifest records
          # on fd 3 and drain a separate pipe of fixed codes, retaining only the first failure.
          failure=$(
            {
              find "$directory" -exec sh -c '
                exec 4>&1 1>&3
                fail() { printf "%s\n" "$1" >&4; exit "$1"; }
                home=$1; limit=$2; shift 2
                for file do
                  rel=${file#"$home/"}
                  case "$rel" in *[!A-Za-z0-9._/-]*) fail 44;; esac
                  [ ! -L "$file" ] || fail 44
                  if [ -d "$file" ]; then
                    [ -r "$file" ] && [ -x "$file" ] || fail 43
                    printf "D\000%s\000" "$rel"
                  elif [ -f "$file" ]; then
                    case "$rel" in *.jsonl) ;; *) continue;; esac
                    [ -r "$file" ] || fail 43
                    before=$(stat -c "%s|%y|%z|%d|%i" -- "$file") || fail 46
                    size=${before%%|*}
                    [ "$size" -le "$limit" ] || fail 45
                    hash=$(sha256sum -- "$file") || fail 46
                    hash=${hash%% *}
                    after=$(stat -c "%s|%y|%z|%d|%i" -- "$file") || fail 46
                    [ "$before" = "$after" ] || fail 46
                    printf "F\000%s\000%s\000%s\000%s\000" "$rel" "$size" "$before" "$hash"
                  else fail 44
                  fi
                done
              ' sh "$home" \#(limits.fileBytes) {} + || printf '46\n'
            } | {
              first=
              while IFS= read -r code; do
                case "$first:$code" in (:43|:44|:45|:46) first=$code;; esac
              done
              printf '%s' "$first"
            }
          )
          [ -z "$failure" ] || exit "$failure"
        done
        printf 'END\000'
        """#
        return "sh -c " + Self.quote(script)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileDigest(_ url: URL, deadline: TimeInterval = .infinity) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var last: UInt8?
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexRemoteLogError.timedOut }
            hash.update(data: data)
            last = data.last
        }
        guard last == nil || last == 10 else { throw CodexRemoteLogError.unstableSource }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
