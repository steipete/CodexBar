import Foundation

#if os(macOS)

public actor NotionSessionStore {
    public struct Session: Codable, Equatable, Sendable {
        public let tokenV2: String
        public let sourceLabel: String

        public init(tokenV2: String, sourceLabel: String) {
            self.tokenV2 = tokenV2
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            "\(NotionUsageFetcher.sessionCookieName)=\(self.tokenV2)"
        }
    }

    public static let shared = NotionSessionStore()

    private var session: Session?
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.fileURL = appSupport
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("notion-session.json")
    }

    #if DEBUG
    init(fileURL: URL) {
        self.fileURL = fileURL
    }
    #endif

    public func setSession(tokenV2: String, sourceLabel: String) {
        let token = tokenV2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            self.clearSession()
            return
        }
        self.hasLoadedFromDisk = true
        self.session = Session(tokenV2: token, sourceLabel: sourceLabel)
        self.saveToDisk()
    }

    public func getSession() -> Session? {
        self.loadFromDiskIfNeeded()
        return self.session
    }

    public func clearSession() {
        self.hasLoadedFromDisk = true
        self.session = nil
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    private func loadFromDiskIfNeeded() {
        guard !self.hasLoadedFromDisk else { return }
        self.hasLoadedFromDisk = true
        CredentialFileWriter.repairPermissions(at: self.fileURL)
        guard let data = try? Data(contentsOf: self.fileURL),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              !session.tokenV2.isEmpty
        else { return }
        self.session = session
    }

    private func saveToDisk() {
        guard let session = self.session,
              let data = try? JSONEncoder().encode(session)
        else {
            try? FileManager.default.removeItem(at: self.fileURL)
            return
        }
        try? CredentialFileWriter.writePrivate(data, to: self.fileURL)
    }
}

#endif
