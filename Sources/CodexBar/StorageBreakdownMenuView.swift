import AppKit
import CodexBarCore
import SwiftUI

struct StorageMenuCardSectionView: View {
    let storageText: String
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage")
                .font(.body)
                .fontWeight(.medium)
            Text(self.storageText)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.top, self.topPadding)
        .padding(.bottom, self.bottomPadding)
        .frame(width: self.width, alignment: .leading)
    }
}

struct StorageBreakdownMenuView: View {
    let footprint: ProviderStorageFootprint
    let width: CGFloat
    let maxHeight: CGFloat

    init(footprint: ProviderStorageFootprint, width: CGFloat, maxHeight: CGFloat = 560) {
        self.footprint = footprint
        self.width = width
        self.maxHeight = maxHeight
    }

    var cleanupRecommendations: [ProviderStorageRecommendation] {
        self.footprint.cleanupRecommendations
    }

    var copyablePaths: [String] {
        let recommendationPaths = self.cleanupRecommendations.map(\.path)
        return self.visibleComponents.map(\.path) + recommendationPaths
    }

    private var visibleComponents: [ProviderStorageFootprint.Component] {
        Array(self.footprint.components.prefix(8))
    }

    private var maxBytes: Int64 {
        max(self.visibleComponents.map(\.totalBytes).max() ?? 0, 1)
    }

    var body: some View {
        ScrollView(.vertical) {
            self.content
        }
        .scrollIndicators(.visible)
        .frame(
            minWidth: self.width,
            idealWidth: self.width,
            maxWidth: self.width,
            maxHeight: self.maxHeight,
            alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Storage")
                    .font(.body)
                    .fontWeight(.medium)
                Text("Total: \(UsageFormatter.byteCountString(self.footprint.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if self.visibleComponents.isEmpty {
                Text("No local data found")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.visibleComponents) { component in
                        self.componentRow(component)
                    }
                }
            }

            if self.footprint.components.count > self.visibleComponents.count {
                Text("\(self.footprint.components.count - self.visibleComponents.count) more items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !self.cleanupRecommendations.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup ideas")
                        .font(.body)
                        .fontWeight(.medium)
                    ForEach(self.cleanupRecommendations) { recommendation in
                        self.recommendationRow(recommendation)
                    }
                }
            }
            if !self.footprint.unreadablePaths.isEmpty {
                Text("\(self.footprint.unreadablePaths.count) unreadable item(s) skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
    }

    private func componentRow(_ component: ProviderStorageFootprint.Component) -> some View {
        let fraction = CGFloat(max(0, min(1, Double(component.totalBytes) / Double(self.maxBytes))))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(component.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(component.path)
                    .layoutPriority(1)
                Spacer()
                StoragePathCopyButton(path: component.path)
                Text(UsageFormatter.byteCountString(component.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    Capsule()
                        .fill(self.providerColor)
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
    }

    private func recommendationRow(_ recommendation: ProviderStorageRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(recommendation.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(UsageFormatter.byteCountString(recommendation.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(recommendation.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(recommendation.path)
                    .layoutPriority(1)
                Spacer()
                StoragePathCopyButton(path: recommendation.path)
            }
            Text(recommendation.consequence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerColor: Color {
        let color = ProviderDescriptorRegistry.descriptor(for: self.footprint.provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
}

struct StoragePathCopyButton: View {
    let path: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            Self.copyToPasteboard(self.path)
            withAnimation(.easeOut(duration: 0.12)) {
                self.didCopy = true
            }
            self.resetTask?.cancel()
            self.resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeOut(duration: 0.2)) {
                    self.didCopy = false
                }
            }
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.didCopy ? "Copied" : "Copy path")
        .accessibilityLabel(self.didCopy ? "Copied" : "Copy path")
    }

    static func copyToPasteboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
