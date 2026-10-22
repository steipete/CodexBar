import CodexBarCore
import Testing
@testable import CodexBarCLI

struct ProviderSelectionRawIDTests {
    @Test
    func `raw provider IDs from the catalog select their own provider`() {
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(ProviderSelection(argument: descriptor.id.rawValue)?.asList == [descriptor.id])
        }
    }

    @Test
    func `alibaba token plan accepts its raw ID and CLI name`() {
        #expect(ProviderSelection(argument: "alibabatokenplan")?.asList == [.alibabatokenplan])
        #expect(ProviderSelection(argument: "alibaba-token-plan")?.asList == [.alibabatokenplan])
    }

    @Test
    func `CLI names keep precedence over raw IDs`() {
        for descriptor in ProviderDescriptorRegistry.all {
            for name in [descriptor.cli.name] + descriptor.cli.aliases {
                #expect(ProviderDescriptorRegistry.cliNameMap[name] == descriptor.id)
            }
        }
    }
}
