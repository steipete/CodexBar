import CodexBarCore

extension UsageProvider {
    var displayName: String {
        ProviderDescriptorRegistry.metadata[self]?.displayName ?? self.rawValue
    }
}
