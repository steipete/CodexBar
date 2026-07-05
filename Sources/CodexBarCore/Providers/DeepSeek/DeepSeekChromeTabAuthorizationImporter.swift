import Foundation

#if os(macOS)
enum DeepSeekChromeTabAuthorizationImporter {
    nonisolated(unsafe) static var importAuthorizationHeaderOverrideForTesting: (() -> String?)?

    private static let authTokenJavaScript =
        "(function(){var keys=['userToken','auth_token','access_token','token'];"
            + "for(var i=0;i<keys.length;i++){"
            + "var raw=localStorage.getItem(keys[i])||sessionStorage.getItem(keys[i])||'';"
            + "if(!raw){continue;}try{var parsed=JSON.parse(raw);if(parsed&&parsed.value){return parsed.value;}}"
            + "catch(e){}return raw;}return '';})()"

    /// Reads a live `auth_token` from an open `platform.deepseek.com` Chrome tab.
    /// Requires Chrome → View → Developer → Allow JavaScript from Apple Events.
    static func importAuthorizationHeader(logger: ((String) -> Void)? = nil) -> String? {
        if let override = self.importAuthorizationHeaderOverrideForTesting {
            return override()
        }

        let log: (String) -> Void = { msg in logger?("[deepseek-tab] \(msg)") }
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "platform.deepseek.com" then
                        set js to "\(Self.authTokenJavaScript)"
                        return execute t javascript js
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("AppleScript launch failed: \(error.localizedDescription)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.localizedCaseInsensitiveContains("apple events") ||
            output.localizedCaseInsensitiveContains("javascript through applescript")
        {
            log(
                "Chrome blocked AppleScript JavaScript. Enable View → Developer → "
                    + "Allow JavaScript from Apple Events, then refresh (⌘R).")
            return nil
        }

        guard !output.isEmpty else {
            log("No platform.deepseek.com tab found in Chrome (or token empty).")
            return nil
        }

        guard let bearer = DeepSeekLocalStorageImporter.bearer(from: output),
              DeepSeekLocalStorageImporter.looksLikeDeepSeekAuthorizationHeader(bearer)
        else {
            log("Chrome tab token is missing or not a valid DeepSeek bearer token.")
            return nil
        }

        log("Read live bearer token from Chrome platform tab.")
        return bearer
    }
}
#endif
