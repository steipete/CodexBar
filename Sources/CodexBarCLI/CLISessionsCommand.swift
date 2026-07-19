import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runSessions(_ values: ParsedValues) async {
        let sessions = await LocalAgentSessionScanner().scan()
        if values.flags.contains("jsonShortcut") {
            Self.printJSON(sessions, pretty: values.flags.contains("pretty"))
        } else {
            print(Self.renderSessionsTable(sessions))
        }
    }

    static func runSessionsFocus(_ values: ParsedValues) async {
        guard let sessionID = values.positional.first, !sessionID.isEmpty else {
            writeStderr("Missing session id.\n")
            platformExit(1)
        }
        let sessions = await LocalAgentSessionScanner().scan()
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            Self.writeStderr("Unknown session: \(sessionID)\n")
            Self.platformExit(1)
        }

        #if os(macOS)
        let result = await MainActor.run {
            SessionWindowFocuser.focus(session)
        }
        switch result {
        case .focused, .activatedApplicationOnly:
            Self.platformExit(0)
        case .failed:
            Self.writeStderr("Could not focus session: \(sessionID)\n")
            Self.platformExit(2)
        }
        #else
        Self.writeStderr("Session focus is only available on macOS.\n")
        Self.platformExit(2)
        #endif
    }

    static func renderSessionsTable(_ sessions: [AgentSession], now: Date = Date()) -> String {
        guard !sessions.isEmpty else { return "No agent sessions found." }
        let rows = sessions.map { session in
            [
                session.state == .active ? "active" : "idle",
                session.provider.rawValue,
                session.source.rawValue,
                session.projectName ?? "—",
                Self.sessionAge(session, now: now),
                session.id,
            ]
        }
        let headers = ["STATE", "PROVIDER", "SOURCE", "PROJECT", "ACTIVITY", "ID"]
        let widths = headers.indices.map { index in
            ([headers[index]] + rows.map { $0[index] }).map(\ .count).max() ?? headers[index].count
        }
        let render: ([String]) -> String = { columns in
            columns.indices.map { index in
                columns[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return ([render(headers)] + rows.map(render)).joined(separator: "\n")
    }

    private static func sessionAge(_ session: AgentSession, now: Date) -> String {
        guard let date = session.lastActivityAt ?? session.startedAt else { return "now" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        if seconds < 86400 {
            return "\(seconds / 3600)h"
        }
        return "\(seconds / 86400)d"
    }
}

struct SessionsOptions: CommanderParsable {
    @Flag(name: .long("json"), help: "Emit JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}

struct SessionsFocusOptions: CommanderParsable {
    @Argument(help: "Session identifier")
    var id: String = ""
}
