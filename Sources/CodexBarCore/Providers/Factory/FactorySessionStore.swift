import Foundation

#if os(macOS)

// MARK: - Factory Session Store

public actor FactorySessionStore {
    public static let shared = FactorySessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private var bearerToken: String?
    private var refreshToken: String?
    private var fileURL: URL
    private var didLoadFromDisk = false

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("factory-session.json")
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        self.didLoadFromDisk = true
        self.sessionCookies = cookies
        self.saveToDisk()
    }

    public func getCookies() -> [HTTPCookie] {
        self.loadFromDiskIfNeeded()
        return self.sessionCookies
    }

    public func clearCookies() {
        self.loadFromDiskIfNeeded()
        self.didLoadFromDisk = true
        self.sessionCookies = []
        self.saveToDisk()
    }

    public func setBearerToken(_ token: String?) {
        self.didLoadFromDisk = true
        self.bearerToken = token
        self.saveToDisk()
    }

    public func getBearerToken() -> String? {
        self.loadFromDiskIfNeeded()
        return self.bearerToken
    }

    public func setRefreshToken(_ token: String?) {
        self.didLoadFromDisk = true
        self.refreshToken = token
        self.saveToDisk()
    }

    public func getRefreshToken() -> String? {
        self.loadFromDiskIfNeeded()
        return self.refreshToken
    }

    public func clearSession() {
        self.didLoadFromDisk = true
        self.sessionCookies = []
        self.bearerToken = nil
        self.refreshToken = nil
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    public func hasValidSession() -> Bool {
        self.loadFromDiskIfNeeded()
        return !self.sessionCookies.isEmpty || self.bearerToken != nil || self.refreshToken != nil
    }

    func resetInMemoryForTesting() {
        self.sessionCookies = []
        self.bearerToken = nil
        self.refreshToken = nil
        self.didLoadFromDisk = false
    }

    func useFileURLForTesting(_ fileURL: URL) {
        self.fileURL = fileURL
        self.sessionCookies = []
        self.bearerToken = nil
        self.refreshToken = nil
        self.didLoadFromDisk = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func saveToDisk() {
        let cookieData = self.sessionCookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            var serializable: [String: Any] = [:]
            for (key, value) in props {
                let keyString = key.rawValue
                if let date = value as? Date {
                    serializable[keyString] = date.timeIntervalSince1970
                    serializable[keyString + "_isDate"] = true
                } else if let url = value as? URL {
                    serializable[keyString] = url.absoluteString
                    serializable[keyString + "_isURL"] = true
                } else if JSONSerialization.isValidJSONObject([value]) ||
                    value is String ||
                    value is Bool ||
                    value is NSNumber
                {
                    serializable[keyString] = value
                }
            }
            return serializable
        }

        var payload: [String: Any] = [:]
        if !cookieData.isEmpty {
            payload["cookies"] = cookieData
        }
        if let bearerToken {
            payload["bearerToken"] = bearerToken
        }
        if let refreshToken {
            payload["refreshToken"] = refreshToken
        }

        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else {
            try? FileManager.default.removeItem(at: self.fileURL)
            return
        }
        try? data.write(to: self.fileURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: self.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return }

        var cookieArray: [[String: Any]] = []
        if let dict = json as? [String: Any] {
            if let stored = dict["cookies"] as? [[String: Any]] {
                cookieArray = stored
            }
            self.bearerToken = dict["bearerToken"] as? String
            self.refreshToken = dict["refreshToken"] as? String
        } else if let stored = json as? [[String: Any]] {
            cookieArray = stored
        }

        self.sessionCookies = cookieArray.compactMap { props in
            var cookieProps: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in props {
                if key.hasSuffix("_isDate") || key.hasSuffix("_isURL") { continue }

                let propKey = HTTPCookiePropertyKey(key)

                if props[key + "_isDate"] as? Bool == true, let interval = value as? TimeInterval {
                    cookieProps[propKey] = Date(timeIntervalSince1970: interval)
                } else if props[key + "_isURL"] as? Bool == true, let urlString = value as? String {
                    cookieProps[propKey] = URL(string: urlString)
                } else {
                    cookieProps[propKey] = value
                }
            }
            return HTTPCookie(properties: cookieProps)
        }
    }

    private func loadFromDiskIfNeeded() {
        guard !self.didLoadFromDisk else { return }
        self.didLoadFromDisk = true
        self.loadFromDisk()
    }
}

#endif
