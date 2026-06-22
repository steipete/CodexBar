import Foundation
import Testing
@testable import CodexBarCore

struct ProxyConfigurationTests {
    @Test
    func `parses an http proxy url`() throws {
        let config = try ProxyConfiguration.parse(from: "http://127.0.0.1:8080")
        #expect(config.type == .http)
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8080)
    }

    @Test
    func `parses a socks5 proxy url`() throws {
        let config = try ProxyConfiguration.parse(from: "socks5://127.0.0.1:1080")
        #expect(config.type == .socks)
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 1080)
    }

    @Test
    func `ignores embedded credentials`() throws {
        let config = try ProxyConfiguration.parse(from: "http://user:pass@proxy.local:3128")
        #expect(config.type == .http)
        #expect(config.host == "proxy.local")
        #expect(config.port == 3128)
    }

    @Test
    func `trims surrounding whitespace`() throws {
        let config = try ProxyConfiguration.parse(from: "  http://127.0.0.1:8080  ")
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8080)
    }

    @Test
    func `defaults missing port by scheme`() throws {
        #expect(try ProxyConfiguration.parse(from: "http://proxy.local").port == 8080)
        #expect(try ProxyConfiguration.parse(from: "socks5://proxy.local").port == 1080)
    }

    @Test
    func `http proxy dictionary sets http and https keys`() throws {
        let dict = try ProxyConfiguration.parse(from: "http://127.0.0.1:8080").connectionProxyDictionary()
        #expect(dict[kCFNetworkProxiesHTTPProxy as String] as? String == "127.0.0.1")
        #expect(dict[kCFNetworkProxiesHTTPPort as String] as? Int == 8080)
        #expect(dict[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #expect(dict[kCFNetworkProxiesHTTPSPort as String] as? Int == 8080)
        #expect(dict[kCFNetworkProxiesSOCKSProxy as String] == nil)
    }

    @Test
    func `socks proxy dictionary sets socks keys`() throws {
        let dict = try ProxyConfiguration.parse(from: "socks5://127.0.0.1:1080").connectionProxyDictionary()
        #expect(dict[kCFNetworkProxiesSOCKSProxy as String] as? String == "127.0.0.1")
        #expect(dict[kCFNetworkProxiesSOCKSPort as String] as? Int == 1080)
        #expect(dict[kCFNetworkProxiesHTTPProxy as String] == nil)
    }

    @Test
    func `rejects an empty url`() {
        #expect(throws: ProxyConfigurationError.empty) {
            try ProxyConfiguration.parse(from: "   ")
        }
    }

    @Test
    func `rejects a missing scheme`() {
        #expect(throws: ProxyConfigurationError.badScheme("")) {
            try ProxyConfiguration.parse(from: "127.0.0.1:8080")
        }
    }

    @Test
    func `rejects an unsupported scheme`() {
        #expect(throws: ProxyConfigurationError.badScheme("ftp")) {
            try ProxyConfiguration.parse(from: "ftp://127.0.0.1:8080")
        }
    }

    @Test
    func `rejects a missing host`() {
        #expect(throws: ProxyConfigurationError.badHost) {
            try ProxyConfiguration.parse(from: "http://:8080")
        }
    }

    @Test
    func `rejects an out of range port`() {
        #expect(throws: ProxyConfigurationError.badPort) {
            try ProxyConfiguration.parse(from: "http://127.0.0.1:70000")
        }
    }
}
