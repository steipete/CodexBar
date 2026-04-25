import CodexBarCore
import Foundation

extension SettingsStore {
    var networkProxyEnabled: Bool {
        get { self.config.networkProxy?.enabled ?? false }
        set {
            self.updateNetworkProxyConfiguration { proxy in
                proxy.enabled = newValue
            }
        }
    }

    var networkProxyScheme: NetworkProxyScheme {
        get { self.config.networkProxy?.scheme ?? .http }
        set {
            self.updateNetworkProxyConfiguration { proxy in
                proxy.scheme = newValue
            }
        }
    }

    var networkProxyHost: String {
        get { self.config.networkProxy?.host ?? "" }
        set {
            self.updateNetworkProxyConfiguration { proxy in
                proxy.host = newValue
            }
        }
    }

    var networkProxyPort: String {
        get { self.config.networkProxy?.port ?? "" }
        set {
            self.updateNetworkProxyConfiguration { proxy in
                proxy.port = newValue
            }
        }
    }

    var networkProxyUsername: String {
        get { self.config.networkProxy?.username ?? "" }
        set {
            self.updateNetworkProxyConfiguration { proxy in
                proxy.username = newValue
            }
        }
    }

    var networkProxyPassword: String {
        get { (try? self.networkProxyPasswordStore.loadPassword()) ?? "" }
        set {
            do {
                try self.networkProxyPasswordStore.storePassword(newValue)
            } catch {
                CodexBarLog.logger(LogCategories.configStore).error("Failed to persist proxy password: \(error)")
            }
            self.syncProviderHTTPClientConfiguration()
        }
    }

    func updateNetworkProxyConfiguration(mutate: (inout NetworkProxyConfiguration) -> Void) {
        self.updateConfig(reason: "network-proxy") { config in
            var proxy = config.networkProxy ?? NetworkProxyConfiguration(
                enabled: false,
                scheme: .http,
                host: "",
                port: "",
                username: "")
            mutate(&proxy)
            config.networkProxy = proxy
        }
        self.syncProviderHTTPClientConfiguration()
    }

    func activeNetworkProxyConfiguration() -> NetworkProxyConfiguration? {
        guard let proxy = self.config.networkProxy, proxy.isActive else { return nil }
        return proxy
    }

    var networkProxyStatusText: String {
        guard let proxy = self.config.networkProxy else {
            return "Proxy is off."
        }
        if !proxy.enabled {
            return "Proxy is configured but disabled."
        }
        let host = proxy.trimmedHost
        guard !host.isEmpty else {
            return "Proxy is enabled, but the host is missing."
        }
        guard let port = proxy.resolvedPort else {
            return "Proxy is enabled, but the port must be between 1 and 65535."
        }
        return "Proxy is active and will route provider requests through \(host):\(port)."
    }

    var networkProxyStatusIsActive: Bool {
        self.activeNetworkProxyConfiguration() != nil
    }

    func syncProviderHTTPClientConfiguration() {
        let password = (try? self.networkProxyPasswordStore.loadPassword()) ?? nil
        ProviderHTTPClient.shared.update(proxy: self.activeNetworkProxyConfiguration(), password: password)
    }
}
