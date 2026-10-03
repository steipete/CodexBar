import Foundation

/// No Foundation search-domain fallback or persistent writes, including for absent keys.
package final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    package init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "InMemoryUserDefaults-\(UUID().uuidString)")!
    }

    override package func object(forKey defaultName: String) -> Any? {
        self.lock.withLock { self.values[defaultName] }
    }

    override package func set(_ value: Any?, forKey defaultName: String) {
        self.lock.withLock { self.values[defaultName] = value }
    }

    override package func removeObject(forKey defaultName: String) {
        self.set(nil as Any?, forKey: defaultName)
    }

    override package func bool(forKey defaultName: String) -> Bool {
        (self.object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    override package func integer(forKey defaultName: String) -> Int {
        (self.object(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    override package func float(forKey defaultName: String) -> Float {
        (self.object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0
    }

    override package func double(forKey defaultName: String) -> Double {
        (self.object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override package func string(forKey defaultName: String) -> String? {
        self.object(forKey: defaultName) as? String
    }

    override package func array(forKey defaultName: String) -> [Any]? {
        self.object(forKey: defaultName) as? [Any]
    }

    override package func dictionary(forKey defaultName: String) -> [String: Any]? {
        self.object(forKey: defaultName) as? [String: Any]
    }

    override package func data(forKey defaultName: String) -> Data? {
        self.object(forKey: defaultName) as? Data
    }

    override package func stringArray(forKey defaultName: String) -> [String]? {
        self.object(forKey: defaultName) as? [String]
    }

    override package func url(forKey defaultName: String) -> URL? {
        self.object(forKey: defaultName) as? URL
    }

    override package func set(_ value: Bool, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override package func set(_ value: Int, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override package func set(_ value: Float, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override package func set(_ value: Double, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override package func set(_ url: URL?, forKey defaultName: String) {
        self.set(url as Any?, forKey: defaultName)
    }

    override package func dictionaryRepresentation() -> [String: Any] {
        self.lock.withLock { self.values }
    }
}
