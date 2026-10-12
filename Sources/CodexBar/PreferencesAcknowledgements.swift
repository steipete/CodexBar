import AppKit
import SwiftUI

/// One third-party component that ships in CodexBar, with its full license and notice text.
/// Metadata lives in `Resources/Acknowledgements.json`; each license is copied verbatim into
/// `Resources/Acknowledgements/<name>.txt`.
struct Acknowledgement: Equatable, Identifiable {
    private struct Entry: Decodable {
        let name: String
        let authors: [String]
        let url: String
        let license: String
    }

    let name: String
    let authors: [String]
    let url: String
    let license: String
    let text: String

    var id: String {
        self.name
    }

    /// Up to two authors, then "and N others"; a lone extra author is named rather than counted.
    /// Formats with the app's selected language so the joined list and "others" text never mix languages.
    func authorSummary(locale: Locale = codexBarLocalizedResourceLocale()) -> String {
        let shown = self.authors.count > 3
            ? Array(self.authors.prefix(2)) + [L("acknowledgements_others", self.authors.count - 2)]
            : self.authors
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: shown) ?? shown.joined(separator: ", ")
    }

    static func load(bundle: Bundle = codexBarLocalizationResourceBundle()) -> [Acknowledgement] {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.map { entry in
            // SwiftPM flattens processed resources, so the license may sit at the bundle root.
            let textURL = bundle.url(forResource: entry.name, withExtension: "txt", subdirectory: "Acknowledgements")
                ?? bundle.url(forResource: entry.name, withExtension: "txt")
            let text = textURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return Acknowledgement(
                name: entry.name,
                authors: entry.authors,
                url: entry.url,
                license: entry.license,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

@MainActor
struct AcknowledgementsView: View {
    let acknowledgements: [Acknowledgement]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The Settings window has no toolbar, so the stack's own back button has nowhere to render.
            Button { self.dismiss() } label: {
                Label(L("tab_about"), systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Form {
                Section {
                    ForEach(self.acknowledgements) { acknowledgement in
                        AcknowledgementRow(acknowledgement: acknowledgement)
                    }
                } footer: {
                    Text(L("acknowledgements_footer"))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L("link_acknowledgements"))
    }
}

@MainActor
private struct AcknowledgementRow: View {
    let acknowledgement: Acknowledgement

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                AcknowledgementDetail(
                    title: L(self.acknowledgement.authors.count == 1
                        ? "acknowledgements_author"
                        : "acknowledgements_authors"))
                {
                    ForEach(self.acknowledgement.authors, id: \.self) { author in
                        Text(author)
                    }
                }
                Divider()
                AcknowledgementDetail(title: L("Website")) {
                    if let url = URL(string: self.acknowledgement.url) {
                        Link(self.acknowledgement.url, destination: url)
                    }
                }
                Divider()
                AcknowledgementDetail(title: L("acknowledgements_license")) {
                    Text(self.acknowledgement.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text(self.acknowledgement.name)
                Text(self.acknowledgement.authorSummary())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(self.acknowledgement.license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct AcknowledgementDetail<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.subheadline.weight(.semibold))
            self.content
        }
    }
}
