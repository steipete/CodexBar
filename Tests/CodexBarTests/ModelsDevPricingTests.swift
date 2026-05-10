import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ModelsDevPricingTests {
    @Test
    func `parses models dev subset`() throws {
        let catalog = try Self.fixtureCatalog()

        #expect(catalog.providers["openai"]?.name == "OpenAI")
        #expect(catalog.providers["anthropic"]?.models["claude-sonnet-4-6"]?.cost?.cacheWrite == 3.75)
        #expect(catalog.providers["anthropic"]?.models["claude-sonnet-4-6"]?.limit?.context == 1_000_000)
    }

    @Test
    func `looks up pricing by provider and model`() throws {
        let catalog = try Self.fixtureCatalog()

        let openAI = try #require(catalog.pricing(providerID: "openai", modelID: "shared-model"))
        let anthropic = try #require(catalog.pricing(providerID: "anthropic", modelID: "shared-model"))

        #expect(openAI.pricing.inputCostPerToken == 1 / 1_000_000.0)
        #expect(openAI.pricing.outputCostPerToken == 2 / 1_000_000.0)
        #expect(anthropic.pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(anthropic.pricing.outputCostPerToken == 4 / 1_000_000.0)
    }

    @Test
    func `does not fall back across providers`() throws {
        let catalog = try Self.fixtureCatalog()

        #expect(catalog.pricing(providerID: "openai", modelID: "claude-sonnet-4-6") == nil)
        #expect(catalog.pricing(providerID: "anthropic", modelID: "gpt-4o-mini") == nil)
    }

    @Test
    func `supports provider scoped alias normalization`() throws {
        let catalog = try Self.fixtureCatalog()

        let anthropic = try #require(catalog.pricing(
            providerID: "anthropic",
            modelID: "anthropic.us-east-1.claude-sonnet-4-6-v1:0"))
        let vertex = try #require(catalog.pricing(
            providerID: "google-vertex-anthropic",
            modelID: "claude-sonnet-4-6"))

        #expect(anthropic.normalizedModelID == "claude-sonnet-4-6")
        #expect(vertex.normalizedModelID == "claude-sonnet-4-6@default")
        #expect(vertex.pricing.inputCostPerToken == 3.1 / 1_000_000.0)
    }

    @Test
    func `converts models dev per million token prices to per token prices`() throws {
        let pricing = try #require(try Self.fixtureCatalog().pricing(
            providerID: "anthropic",
            modelID: "claude-sonnet-4-6")?
            .pricing)

        #expect(pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(pricing.outputCostPerToken == 15 / 1_000_000.0)
        #expect(pricing.cacheReadInputCostPerToken == 0.3 / 1_000_000.0)
        #expect(pricing.cacheCreationInputCostPerToken == 3.75 / 1_000_000.0)
        #expect(pricing.thresholdTokens == 200_000)
        #expect(pricing.inputCostPerTokenAboveThreshold == 6 / 1_000_000.0)
        #expect(pricing.outputCostPerTokenAboveThreshold == 22.5 / 1_000_000.0)
        #expect(pricing.cacheReadInputCostPerTokenAboveThreshold == 0.6 / 1_000_000.0)
        #expect(pricing.cacheCreationInputCostPerTokenAboveThreshold == 7.5 / 1_000_000.0)
    }

    @Test
    func `stale cache is still readable`() throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let load = ModelsDevCache.load(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root)

        #expect(load.artifact != nil)
        #expect(load.isStale)
        #expect(load.error == nil)
    }

    @Test
    func `pipeline lookup reads cached pricing`() throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `network failure preserves last valid cache`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(result: .failure(MockError.failed))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `refresh preserves cache when fetched catalog drops cached provider`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let partialCatalog = Data("""
        {
          "openai": { "id": 7, "models": [] },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((partialCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `refresh preserves cache when fetched catalog drops cached model`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let partialCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4-6@default": {
                "id": "claude-sonnet-4-6@default",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((partialCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `refresh updates cache when fetched catalog renames model key but keeps id`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let renamedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini-renamed": {
                "id": "gpt-4o-mini",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4-6-renamed": {
                "id": "claude-sonnet-4-6@default",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((renamedCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.normalizedModelID == "gpt-4o-mini")
        #expect(lookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `refresh preserves cache when fetched matching model is not priceable`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let partialCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini": {
                "id": "gpt-4o-mini",
                "cost": { "input": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4-6@default": {
                "id": "claude-sonnet-4-6@default",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((partialCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `refresh updates cache when fetched catalog canonicalizes alias model id`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let canonicalizedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini": {
                "id": "gpt-4o-mini",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((canonicalizedCatalog, Self.response(status: 200))))))

        let defaultLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "claude-sonnet-4-6@default",
            cacheRoot: root))
        let baseLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "claude-sonnet-4-6",
            cacheRoot: root))

        #expect(defaultLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
        #expect(baseLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `refresh preserves cache when fetched catalog only has different pinned snapshot`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        let cachedCatalog = try Self.catalog("""
        {
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4@20250101": {
                "id": "claude-sonnet-4@20250101",
                "cost": { "input": 3, "output": 15 }
              }
            }
          }
        }
        """)
        ModelsDevCache.save(catalog: cachedCatalog, fetchedAt: old, cacheRoot: root)

        let fetchedCatalog = Data("""
        {
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4@20250201": {
                "id": "claude-sonnet-4@20250201",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((fetchedCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "claude-sonnet-4@20250101",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 3 / 1_000_000.0)
    }

    @Test
    func `refresh ignores unpriceable models in old cache continuity check`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        let cachedCatalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini": {
                "id": "gpt-4o-mini",
                "cost": { "input": 0.15, "output": 0.6 }
              },
              "unpriced-preview": {
                "id": "unpriced-preview"
              }
            }
          }
        }
        """)
        ModelsDevCache.save(catalog: cachedCatalog, fetchedAt: old, cacheRoot: root)

        let fetchedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini": {
                "id": "gpt-4o-mini",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((fetchedCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `fresh cache does not refresh`() async throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(),
            cacheRoot: root,
            client: ModelsDevClient(transport: transport))

        #expect(transport.calls == 0)
    }

    @Test
    func `corrupt cache is ignored safely`() throws {
        let root = try Self.cacheRoot()
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let load = ModelsDevCache.load(cacheRoot: root)

        #expect(load.artifact == nil)
        #expect(load.isStale)
        #expect(load.error == .invalidJSON)
    }

    @Test
    func `client fetches with mock transport`() async throws {
        let data = try Self.fixtureData()
        let client = ModelsDevClient(transport: MockTransport(result: .success((data, Self.response(status: 200)))))

        let catalog = try await client.fetchCatalog()

        #expect(catalog.providers["google-vertex-anthropic"]?.models["claude-sonnet-4-6@default"]?.cost?.input == 3.1)
    }

    @Test
    func `client reports http and json failures`() async throws {
        let data = try Self.fixtureData()
        let httpClient = ModelsDevClient(transport: MockTransport(result: .success((data, Self.response(status: 500)))))
        let jsonClient = ModelsDevClient(transport: MockTransport(
            result: .success((Data("not json".utf8), Self.response(status: 200)))))

        await #expect(throws: ModelsDevClient.Error.httpStatus(500)) {
            _ = try await httpClient.fetchCatalog()
        }
        await #expect(throws: ModelsDevClient.Error.invalidJSON) {
            _ = try await jsonClient.fetchCatalog()
        }
    }

    private static func fixtureData() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "models-dev-subset",
            withExtension: "json",
            subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func fixtureCatalog() throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: self.fixtureData())
    }

    private static func catalog(_ json: String) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-modelsdev-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://models.dev/api.json")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
    }
}

private enum MockError: Error {
    case failed
}

private struct MockTransport: ModelsDevHTTPTransport {
    let result: Result<(Data, URLResponse), Error>

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try self.result.get()
    }
}

private final class TrackingTransport: ModelsDevHTTPTransport, @unchecked Sendable {
    private(set) var calls = 0
    let result: Result<(Data, URLResponse), Error>

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        self.calls += 1
        return try self.result.get()
    }
}
