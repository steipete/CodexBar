#if DEBUG
import Foundation

/// Dictionary-backed defaults: absent keys cannot fall through to user preference domains.
final class RemoteCostProofDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "RemoteCostProofDefaults-\(UUID().uuidString)")!
    }

    override func object(forKey defaultName: String) -> Any? {
        self.lock.withLock { self.values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        self.lock.withLock { self.values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        self.set(nil as Any?, forKey: defaultName)
    }

    override func bool(forKey defaultName: String) -> Bool {
        (self.object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        (self.object(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    override func float(forKey defaultName: String) -> Float {
        (self.object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        (self.object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override func string(forKey defaultName: String) -> String? {
        self.object(forKey: defaultName) as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        self.object(forKey: defaultName) as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        self.object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        self.object(forKey: defaultName) as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        self.object(forKey: defaultName) as? [String]
    }

    override func url(forKey defaultName: String) -> URL? {
        self.object(forKey: defaultName) as? URL
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Double, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        self.set(url as Any?, forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        self.lock.withLock { self.values }
    }
}

#endif
