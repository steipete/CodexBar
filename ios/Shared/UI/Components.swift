import SwiftUI

/// Provider glyph: bundled vector icon when available, otherwise an SF Symbol on an accent chip.
struct ProviderIconView: View {
    let provider: UsageProvider
    var size: CGFloat = 28

    private var visuals: ProviderVisuals { ProviderVisuals(provider: provider) }

    var body: some View {
        Group {
            if let asset = visuals.iconAssetName, UIImage(named: asset) != nil {
                Image(asset)
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
            } else {
                Image(systemName: visuals.fallbackSymbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(visuals.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(visuals.accent.opacity(0.14)))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(visuals.accent.opacity(0.22), lineWidth: 0.5))
    }
}

/// A slim capsule usage bar showing remaining percentage with a tone-mapped fill.
struct UsageBar: View {
    let remainingPercent: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let fraction = max(0, min(1, (remainingPercent ?? 0) / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(UsageTone.color(remainingPercent: remainingPercent).gradient)
                    .frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(UsageFormat.percent(remainingPercent)) remaining")
    }
}

/// A circular gauge ring used on cards and in widgets.
struct UsageRing: View {
    let remainingPercent: Double?
    var lineWidth: CGFloat = 6
    var showsLabel = true

    var body: some View {
        let fraction = max(0, min(1, (remainingPercent ?? 0) / 100))
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    UsageTone.color(remainingPercent: remainingPercent).gradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLabel {
                Text(UsageFormat.percent(remainingPercent))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

/// A labelled usage row (window title + bar + percent) used on the detail screen.
struct UsageRowView: View {
    let row: WidgetSnapshot.WidgetUsageRowSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(UsageFormat.percent(row.percentLeft))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(UsageTone.color(remainingPercent: row.percentLeft))
                    .contentTransition(.numericText())
            }
            UsageBar(remainingPercent: row.percentLeft)
        }
    }
}
