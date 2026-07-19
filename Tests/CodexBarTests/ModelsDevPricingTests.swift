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
    func `supports provider scoped model normalization`() throws {
        let catalog = try Self.fixtureCatalog()

        let anthropic = try #require(catalog.pricing(
            providerID: "anthropic",
            modelID: "us.anthropic.claude-sonnet-4-6"))
        let vertex = try #require(catalog.pricing(
            providerID: "google-vertex-anthropic",
            modelID: "claude-sonnet-4-6"))

        #expect(anthropic.normalizedModelID == "claude-sonnet-4-6")
        #expect(vertex.normalizedModelID == "claude-sonnet-4-6")
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
}

extension ModelsDevPricingTests {
    @Test
    func `unknown model refresh makes newly published pricing available`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 10000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-901),
            cacheRoot: root)
        let refreshed = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } }
            }
          }
        }
        """.utf8)
        let transport = TrackingTransport(result: .success((refreshed, Self.response(status: 200))))
        let client = ModelsDevClient(transport: transport)

        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["gpt-new"],
            now: now,
            cacheRoot: root,
            client: client)
        #expect(outcome == .pricingAvailable)
        #expect(transport.calls == 1)
        #expect(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-new",
            cacheRoot: root) != nil)
    }

    @Test
    func `unknown model refresh is bounded per provider cache`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 20000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-901),
            cacheRoot: root)
        let transport = try TrackingTransport(result: .success((
            JSONEncoder().encode(Self.fixtureCatalog()),
            Self.response(status: 200))))
        let client = ModelsDevClient(transport: transport)

        let first = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["still-unknown"],
            now: now,
            cacheRoot: root,
            client: client)
        let second = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["another-unknown-model"],
            now: now.addingTimeInterval(60),
            cacheRoot: root,
            client: client)

        #expect(first == .unavailable)
        #expect(second == .unavailable)
        #expect(transport.calls == 1)
    }

    @Test
    func `known requested model does not mask an unresolved unknown model`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 25000)
        let catalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "already-priced": { "id": "already-priced", "cost": { "input": 1, "output": 2 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "catalog-anchor": { "id": "catalog-anchor", "cost": { "input": 3, "output": 4 } }
            }
          }
        }
        """)
        ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: now.addingTimeInterval(-901),
            cacheRoot: root)
        let transport = try TrackingTransport(result: .success((
            JSONEncoder().encode(catalog),
            Self.response(status: 200))))

        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["already-priced", "still-unknown"],
            now: now,
            cacheRoot: root,
            client: ModelsDevClient(transport: transport))

        #expect(outcome == .unavailable)
        #expect(transport.calls == 1)
    }

    @Test
    func `pricing added by a completed background refresh requests a rescan`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 30000)
        let refreshed = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)
        let refreshedCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: refreshed)
        ModelsDevCache.save(catalog: refreshedCatalog, fetchedAt: now, cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))

        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["gpt-new"],
            now: now,
            cacheRoot: root,
            client: ModelsDevClient(transport: transport))

        #expect(outcome == .pricingAvailable)
        #expect(transport.calls == 0)
    }

    @Test
    func `ttl and unknown model refreshes share one download`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 40000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: root)
        let transport = try TrackingTransport(
            result: .success((JSONEncoder().encode(Self.fixtureCatalog()), Self.response(status: 200))),
            delayNanoseconds: 100_000_000)
        let client = ModelsDevClient(transport: transport)

        async let ttl: Void = ModelsDevPricingPipeline.refreshIfNeeded(
            now: now,
            cacheRoot: root,
            client: client)
        async let unknown = ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["still-unknown"],
            now: now,
            cacheRoot: root,
            client: client)
        _ = await (ttl, unknown)

        #expect(transport.calls == 1)
    }

    @Test
    func `completed ttl refresh bounds a following unknown model refresh`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 45000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: root)
        let transport = try TrackingTransport(result: .success((
            JSONEncoder().encode(Self.fixtureCatalog()),
            Self.response(status: 200))))
        let client = ModelsDevClient(transport: transport)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: now,
            cacheRoot: root,
            client: client)
        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["still-unknown"],
            now: now,
            cacheRoot: root,
            client: client)

        #expect(outcome == .unavailable)
        #expect(transport.calls == 1)
    }

    @Test
    func `failed ttl refresh bounds a following unknown model refresh within cooldown`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 46000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))
        let client = ModelsDevClient(transport: transport)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: now,
            cacheRoot: root,
            client: client)
        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["still-unknown"],
            now: now,
            cacheRoot: root,
            client: client)

        #expect(outcome == .unavailable)
        #expect(transport.calls == 1)
    }

    @Test
    func `failed unknown model refresh bounds a following ttl refresh within cooldown`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 47000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))
        let client = ModelsDevClient(transport: transport)

        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["still-unknown"],
            now: now,
            cacheRoot: root,
            client: client)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: now,
            cacheRoot: root,
            client: client)

        #expect(outcome == .unavailable)
        #expect(transport.calls == 1)
    }

    @Test
    func `ttl refresh rechecks cache freshness after coordination`() async throws {
        let root = try Self.cacheRoot()
        let now = Date(timeIntervalSince1970: 48000)
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: now.addingTimeInterval(-ModelsDevCache.ttlSeconds - 1),
            cacheRoot: root)
        #expect(ModelsDevCache.load(now: now, cacheRoot: root).isStale)

        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: now, cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))
        let cacheIsCurrent = await ModelsDevPricingPipeline.refreshStaleCache(
            now: now,
            cacheRoot: root,
            client: ModelsDevClient(transport: transport))

        #expect(cacheIsCurrent)
        #expect(transport.calls == 0)
    }

    @Test
    func `failed cache save does not report pricing available`() async {
        let root = URL(fileURLWithPath: "/dev/null", isDirectory: true)
        let now = Date(timeIntervalSince1970: 50000)
        let refreshed = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)

        let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: "openai",
            modelIDs: ["gpt-new"],
            now: now,
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((refreshed, Self.response(status: 200))))))

        #expect(outcome == .unavailable)
    }

    @Test
    func `refresh accepts model churn and preserves removed pricing as fallback`() async throws {
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
              },
              "provider-a-new": {
                "id": "provider-a-new",
                "cost": { "input": 7, "output": 8 }
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
                result: .success((partialCatalog, Self.response(status: 200))))))

        let oldLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))
        let newLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "provider-a-new",
            cacheRoot: root))
        let updatedLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "shared-model",
            cacheRoot: root))

        #expect(oldLookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
        #expect(newLookup.pricing.inputCostPerToken == 7 / 1_000_000.0)
        #expect(updatedLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `accumulated fallback models do not freeze later refreshes`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        let cachedCatalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "provider-a-old": { "id": "provider-a-old", "cost": { "input": 1, "output": 2 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-old": { "id": "provider-b-old", "cost": { "input": 3, "output": 4 } }
            }
          },
          "stale-a": {
            "id": "stale-a",
            "models": {
              "model-a": { "id": "model-a", "cost": { "input": 5, "output": 6 } }
            }
          },
          "stale-b": {
            "id": "stale-b",
            "models": {
              "model-b": { "id": "model-b", "cost": { "input": 7, "output": 8 } }
            }
          },
          "stale-c": {
            "id": "stale-c",
            "models": {
              "model-c": { "id": "model-c", "cost": { "input": 9, "output": 10 } }
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
              "provider-a-new": { "id": "provider-a-new", "cost": { "input": 11, "output": 12 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-new": { "id": "provider-b-new", "cost": { "input": 13, "output": 14 } }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((fetchedCatalog, Self.response(status: 200))))))

        let newLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "provider-a-new",
            cacheRoot: root))
        let fallbackLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "stale-a",
            modelID: "model-a",
            cacheRoot: root))

        #expect(newLookup.pricing.inputCostPerToken == 11 / 1_000_000.0)
        #expect(fallbackLookup.pricing.inputCostPerToken == 5 / 1_000_000.0)
    }

    @Test
    func `historical fallback does not overwrite a refreshed model that reuses its map key`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        let cachedCatalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "rolling": { "id": "provider-a-old", "cost": { "input": 1, "output": 2 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-anchor": { "id": "provider-b-anchor", "cost": { "input": 3, "output": 4 } }
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
              "rolling": { "id": "provider-a-new", "cost": { "input": 99, "output": 100 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-anchor": { "id": "provider-b-anchor", "cost": { "input": 3, "output": 4 } }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((fetchedCatalog, Self.response(status: 200))))))

        let freshLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "provider-a-new",
            cacheRoot: root))
        let fallbackLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "provider-a-old",
            cacheRoot: root))

        #expect(freshLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
        #expect(fallbackLookup.pricing.inputCostPerToken == 1 / 1_000_000.0)
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
              "renamed-model-key": {
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
              "renamed-vertex-key": {
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
                result: .success((partialCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))
        let updatedLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "shared-model",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
        #expect(updatedLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `refresh updates cache when fetched catalog canonicalizes alias model id`() async throws {
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
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 3, "output": 15 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "snapshot-model@20250101": {
                "id": "snapshot-model@20250101",
                "cost": { "input": 3.1, "output": 15.1 }
              }
            }
          }
        }
        """)
        ModelsDevCache.save(catalog: cachedCatalog, fetchedAt: old, cacheRoot: root)

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
              "snapshot-model-20250101": {
                "id": "snapshot-model-20250101",
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

        let aliasLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "snapshot-model@20250101",
            cacheRoot: root))
        let canonicalLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "snapshot-model-20250101",
            cacheRoot: root))

        #expect(aliasLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
        #expect(canonicalLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `fallback merge treats default alias as the canonical base model`() throws {
        let cachedCatalog = try Self.catalog("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "base-model@default": {
                "id": "base-model@default",
                "cost": { "input": 3, "output": 15 }
              }
            }
          }
        }
        """)
        let refreshedCatalog = try Self.catalog("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "base-model": {
                "id": "base-model",
                "cost": { "input": 99, "output": 100 }
              }
            }
          }
        }
        """)

        let merged = refreshedCatalog.mergingFallbackPricing(from: cachedCatalog)
        let aliasLookup = try #require(merged.pricing(
            providerID: "anthropic",
            modelID: "base-model@default"))

        #expect(aliasLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
        #expect(merged.providers["anthropic"]?.models.count == 1)
    }

    @Test
    func `fallback merge treats provider version alias as the canonical base model`() throws {
        let cachedCatalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "openai/base-model-v1:0": {
                "id": "openai/base-model-v1:0",
                "cost": { "input": 3, "output": 15 }
              }
            }
          }
        }
        """)
        let refreshedCatalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "base-model": {
                "id": "base-model",
                "cost": { "input": 99, "output": 100 }
              }
            }
          }
        }
        """)

        let merged = refreshedCatalog.mergingFallbackPricing(from: cachedCatalog)
        let aliasLookup = try #require(merged.pricing(
            providerID: "openai",
            modelID: "openai/base-model-v1:0"))

        #expect(aliasLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
        #expect(merged.providers["openai"]?.models.count == 1)
    }

    @Test
    func `refresh keeps historical pinned pricing while accepting a new snapshot`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        let cachedCatalog = try Self.catalog("""
        {
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "snapshot-model@20250101": {
                "id": "snapshot-model@20250101",
                "cost": { "input": 3, "output": 15 }
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
              "provider-a-anchor": {
                "id": "provider-a-anchor",
                "cost": { "input": 1, "output": 2 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-anchor": {
                "id": "provider-b-anchor",
                "cost": { "input": 3, "output": 4 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "snapshot-model@20250201": {
                "id": "snapshot-model@20250201",
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

        let oldLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "snapshot-model@20250101",
            cacheRoot: root))
        let newLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "google-vertex-anthropic",
            modelID: "snapshot-model@20250201",
            cacheRoot: root))

        #expect(oldLookup.pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(newLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `refresh preserves dated snapshot when fetched catalog only keeps base model`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        let cachedCatalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "historical-map-key": {
                "id": "snapshot-model-2025-01-01",
                "cost": { "input": 3, "output": 15 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-anchor": {
                "id": "provider-b-anchor",
                "cost": { "input": 3, "output": 4 }
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
              "snapshot-model": {
                "id": "snapshot-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-anchor": {
                "id": "provider-b-anchor",
                "cost": { "input": 3, "output": 4 }
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

        let snapshotLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "snapshot-model-2025-01-01",
            cacheRoot: root))
        let baseLookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "snapshot-model",
            cacheRoot: root))

        #expect(snapshotLookup.pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(baseLookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `compact snapshot alias prefers snapshot pricing over base pricing`() throws {
        let catalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "snapshot-model": {
                "id": "snapshot-model",
                "cost": { "input": 99, "output": 100 }
              },
              "snapshot-model-20250101": {
                "id": "snapshot-model-20250101",
                "cost": { "input": 3, "output": 15 }
              }
            }
          }
        }
        """)

        let lookup = try #require(catalog.pricing(
            providerID: "openai",
            modelID: "snapshot-model@20250101"))

        #expect(lookup.pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(lookup.normalizedModelID == "snapshot-model-20250101")
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
              "unpriced-model": {
                "id": "unpriced-model"
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
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "provider-b-anchor": {
                "id": "provider-b-anchor",
                "cost": { "input": 3, "output": 4 }
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
    func `serves decoded catalog from memo while the file is unchanged`() throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)

        // Pin a whole-second modification date so the memo key (which compares modification dates) round-trips
        // deterministically through the filesystem.
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)

        // Prime the in-memory memo with a successful decode.
        let primed = ModelsDevCache.load(cacheRoot: root)
        let cachedArtifact = try #require(primed.artifact)

        // Corrupt the file contents while preserving its size and modification date, so the on-disk identity
        // the memo keys on is unchanged. A re-decode would now fail; a memo hit returns the cached artifact.
        let size = try #require(
            try (FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber).intValue
        try Data(repeating: 0, count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)

        let reloaded = ModelsDevCache.load(cacheRoot: root)

        #expect(reloaded.error == nil)
        #expect(reloaded.artifact == cachedArtifact)
    }

    @Test
    func `saving a new catalog invalidates the memo`() throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)
        #expect(ModelsDevCache.load(cacheRoot: root).artifact?.catalog.providers["openai"] != nil)

        // Overwriting the cache must drop the memo so the next load reflects the freshly written catalog.
        ModelsDevCache.save(catalog: ModelsDevCatalog(providers: [:]), fetchedAt: Date(), cacheRoot: root)
        let reloaded = ModelsDevCache.load(cacheRoot: root)

        #expect(reloaded.error == nil)
        #expect(reloaded.artifact?.catalog.providers.isEmpty == true)
    }

    @Test
    func `serves a failed load from memo while the file is unchanged`() throws {
        let root = try Self.cacheRoot()
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let validData = try Self.encodedArtifactData()

        // Write invalid JSON of the same size as a valid encoding, with a pinned modification date, then prime
        // the memo with the resulting failure.
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data(repeating: 0x7B, count: validData.count).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)
        #expect(ModelsDevCache.load(cacheRoot: root).error == .invalidJSON)

        // Replace the bytes with a valid encoding of identical size + modification date. A re-read would now
        // succeed, so a returned failure proves the unchanged-identity file was not read and decoded again.
        try validData.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)
        let reloaded = ModelsDevCache.load(cacheRoot: root)

        #expect(reloaded.error == .invalidJSON)
        #expect(reloaded.artifact == nil)
    }

    @Test
    func `client fetches with mock transport`() async throws {
        let data = try Self.fixtureData()
        let client = ModelsDevClient(transport: MockTransport(result: .success((data, Self.response(status: 200)))))

        let catalog = try await client.fetchCatalog()

        #expect(catalog.providers["google-vertex-anthropic"]?.models["claude-sonnet-4-6"]?.cost?.input == 3.1)
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

    /// A valid `ModelsDevCacheArtifact` encoding, written the same way `ModelsDevCache.save` writes the file.
    private static func encodedArtifactData() throws -> Data {
        let artifact = try ModelsDevCacheArtifact(
            version: ModelsDevCache.artifactVersion,
            fetchedAt: Date(timeIntervalSince1970: 0),
            catalog: self.fixtureCatalog())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(artifact)
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
    private let lock = NSLock()
    private var callCount = 0
    let result: Result<(Data, URLResponse), Error>
    let delayNanoseconds: UInt64

    var calls: Int {
        self.lock.withLock { self.callCount }
    }

    init(result: Result<(Data, URLResponse), Error>, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        self.lock.withLock { self.callCount += 1 }
        if self.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: self.delayNanoseconds)
        }
        return try self.result.get()
    }
}
