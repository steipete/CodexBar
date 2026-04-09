import CodexBarCore
import Testing

@Suite
struct AppIdentityTests {
    @Test
    func userDefaultsDomainsPreferForkBeforeLegacy() {
        #expect(
            AppIdentity.userDefaultsDomains(for: AppIdentity.bundleID)
                == [AppIdentity.bundleID, AppIdentity.legacyBundleID])
    }

    @Test
    func debugAppGroupsIncludeLegacyFallback() {
        #expect(
            AppIdentity.appGroupIDs(for: AppIdentity.debugBundleID)
                == [AppIdentity.debugAppGroupID, AppIdentity.legacyDebugAppGroupID])
    }

    @Test
    func keychainServicesIncludeLegacyFallback() {
        #expect(
            AppIdentity.keychainCacheServices()
                == [AppIdentity.keychainCacheService, AppIdentity.legacyKeychainCacheService])
    }
}
