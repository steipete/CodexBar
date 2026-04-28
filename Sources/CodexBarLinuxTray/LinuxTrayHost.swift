import Foundation

protocol LinuxTrayHost: Sendable {
    func start(onActivate: (@Sendable () -> Void)?) async
    func update(summary: String, tooltip: String, iconName: String) async
    func stop() async
}

actor ZenityTrayHost: LinuxTrayHost {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutTask: Task<Void, Never>?
    private var onActivate: (@Sendable () -> Void)?
    private var activeIconName = "utilities-terminal"

    func start(onActivate: (@Sendable () -> Void)?) async {
        self.onActivate = onActivate
        await self.ensureStarted()
    }

    func update(summary: String, tooltip: String, iconName: String) async {
        self.activeIconName = iconName
        await self.ensureStarted()
        self.sendLine("icon:\(self.escapeLine(iconName))")
        self.sendLine("message:\(self.escapeLine(summary))")
        self.sendLine("tooltip:\(self.escapeLine(tooltip))")
        self.sendLine("visible:true")
    }

    func stop() async {
        self.stdoutTask?.cancel()
        self.stdoutTask = nil
        self.process?.terminate()
        self.process = nil
        self.stdinPipe = nil
    }

    private func ensureStarted() async {
        if let process = self.process, process.isRunning { return }
        self.stdoutTask?.cancel()
        self.stdoutTask = nil

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zenity")
        process.arguments = [
            "--notification",
            "--listen",
            "--text=CodexBar",
            "--icon-name=\(self.activeIconName)",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            self.process = process
            self.stdinPipe = input
            self.stdoutTask = Task.detached(priority: .utility) { [weak self] in
                await self?.readEvents(from: output.fileHandleForReading)
            }
        } catch {
            self.process = nil
            self.stdinPipe = nil
        }
    }

    private func readEvents(from handle: FileHandle) async {
        while !Task.isCancelled {
            let data = handle.availableData
            if data.isEmpty { return }
            guard let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty
            else {
                continue
            }

            // zenity emits a line when the tray icon is activated.
            self.onActivate?()
            if line == "quit" {
                return
            }
        }
    }

    private func sendLine(_ line: String) {
        guard let writer = self.stdinPipe?.fileHandleForWriting else { return }
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        writer.write(data)
    }

    private func escapeLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

actor StdoutTrayHost: LinuxTrayHost {
    func start(onActivate: (@Sendable () -> Void)?) async {
        _ = onActivate
    }

    func update(summary: String, tooltip: String, iconName: String) async {
        print("[\(iconName)] \(summary)\n\(tooltip)\n")
    }

    func stop() async {}
}
