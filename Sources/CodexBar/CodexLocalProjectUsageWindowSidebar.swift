import AppKit
import CodexBarCore
import SwiftUI

struct CodexWorkspaceSidebar: View {
    let presentation: CodexLocalProjectUsageWindowPresentation
    let showsEstimatedCost: Bool
    @Binding var selectedDestinationID: String?
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        let maximumTokens = max(self.presentation.displayedProjectTokens.values.max() ?? 0, 1)
        let allWorkspacesID = CodexLocalProjectUsageWindowDestination.allWorkspacesID
        let orderedDestinationIDs = [allWorkspacesID] + self.presentation.rankedProjects.map(\.id)

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Button {
                        self.selectedDestinationID = allWorkspacesID
                        self.keyboardFocus = true
                    } label: {
                        CodexAllWorkspacesSidebarRow(
                            tokens: self.presentation.allWorkspaceTokens,
                            projectCount: self.presentation.rankedProjects.count,
                            selected: self.presentation.isAllWorkspaces)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(allWorkspacesID)
                    .accessibilityAddTraits(self.presentation.isAllWorkspaces ? .isSelected : [])

                    ForEach(self.presentation.rankedProjects) { project in
                        Button {
                            self.selectedDestinationID = project.id
                            self.keyboardFocus = true
                        } label: {
                            CodexWorkspaceSidebarProjectRow(
                                project: project,
                                tokens: self.presentation.displayedProjectTokens[project.id] ?? 0,
                                sessionCount: self.presentation.projectSessionCounts[project.id] ?? project
                                    .sessionCount,
                                maximumTokens: maximumTokens,
                                showsEstimatedCost: self.showsEstimatedCost,
                                selected: self.presentation.selectedProject?.id == project.id)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(project.id)
                        .accessibilityAddTraits(
                            self.presentation.selectedProject?.id == project.id ? .isSelected : [])
                        .contextMenu {
                            if let path = project.path {
                                Button(L("codex_workspaces_copy_path")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(path, forType: .string)
                                }
                                Button(L("codex_workspaces_reveal_in_finder")) {
                                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                                }
                            }
                        }
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused(self.$keyboardFocus)
            .contentMargins(.horizontal, 7, for: .scrollContent)
            .contentMargins(.vertical, 8, for: .scrollContent)
            .onMoveCommand { direction in
                let selectionDirection: CodexWorkspaceSidebarSelectionDirection? = switch direction {
                case .up:
                    .up
                case .down:
                    .down
                default:
                    nil
                }
                guard let selectionDirection,
                      let nextID = CodexWorkspaceSidebarSelectionNavigator.movingSelection(
                          from: self.selectedDestinationID,
                          direction: selectionDirection,
                          orderedIDs: orderedDestinationIDs)
                else { return }
                self.selectedDestinationID = nextID
                self.keyboardFocus = true
                proxy.scrollTo(nextID, anchor: .center)
            }
            .onAppear {
                self.selectedDestinationID = self.presentation.selectedDestinationID
            }
            .onChange(of: self.presentation.selectedDestinationID) { _, normalizedID in
                guard self.selectedDestinationID != normalizedID else { return }
                self.selectedDestinationID = normalizedID
            }
        }
        .background {
            if #unavailable(macOS 26.0) {
                CodexWorkspaceSidebarMaterial().ignoresSafeArea()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("codex_workspaces_title"))
    }
}

@MainActor
private struct CodexWorkspaceSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        self.configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        self.configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
    }
}

enum CodexWorkspaceSidebarSelectionDirection {
    case up
    case down
}

enum CodexWorkspaceSidebarSelectionNavigator {
    static func movingSelection(
        from currentID: String?,
        direction: CodexWorkspaceSidebarSelectionDirection,
        orderedIDs: [String]) -> String?
    {
        guard !orderedIDs.isEmpty else { return nil }
        guard let currentID, let currentIndex = orderedIDs.firstIndex(of: currentID) else {
            return orderedIDs[0]
        }

        let offset = direction == .up ? -1 : 1
        let nextIndex = min(max(currentIndex + offset, 0), orderedIDs.count - 1)
        return orderedIDs[nextIndex]
    }
}

private struct CodexAllWorkspacesSidebarRow: View {
    let tokens: Int?
    let projectCount: Int
    let selected: Bool

    var body: some View {
        CodexWorkspaceSelectionSurface(selected: self.selected) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(self.selected ? Color.accentColor : Color.secondary)
                    Text(L("codex_workspaces_all_workspaces"))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(self.tokens.map(UsageFormatter.tokenCountString) ?? "—")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                Text(L("codex_workspaces_workspace_count", self.projectCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CodexWorkspaceSidebarProjectRow: View {
    let project: CodexLocalProjectUsage
    let tokens: Int
    let sessionCount: Int
    let maximumTokens: Int
    let showsEstimatedCost: Bool
    let selected: Bool

    var body: some View {
        CodexWorkspaceSelectionSurface(selected: self.selected) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    self.statusIcon
                    Text(self.project.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if self.project.severity == .high {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 6)
                    Text(UsageFormatter.tokenCountString(self.tokens))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(self.project.severity == .high ? Color.red : Color.primary)
                }
                Text(self.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 3)
                GeometryReader { geometry in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor.opacity(self.selected ? 0.9 : 0.52))
                                .frame(width: geometry.size.width * self.relativeUsage)
                        }
                }
                .frame(height: 3)
                .padding(.top, 7)
                HStack(spacing: 6) {
                    if self.showsEstimatedCost {
                        Text(self.costText)
                    }
                    Text(L("codex_workspaces_session_count", self.sessionCount))
                    if let model = self.project.topModel {
                        Text(model).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityDescription)
        .accessibilityValue(L("codex_workspaces_relative_usage_accessibility", Int(self.relativeUsage * 100)))
        .help(L("codex_workspaces_relative_usage_tooltip", Int(self.relativeUsage * 100)))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch self.project.severity {
        case .high:
            Circle().fill(.red).frame(width: 7, height: 7)
        case .elevated:
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 7, height: 7)
        case .normal:
            Circle().fill(.green).frame(width: 7, height: 7)
        }
    }

    private var relativeUsage: CGFloat {
        min(max(CGFloat(self.tokens) / CGFloat(max(self.maximumTokens, 1)), 0), 1)
    }

    private var displayPath: String {
        guard let path = self.project.path else { return L("codex_workspaces_chats_description") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var costText: String {
        switch self.project.costEstimate.coverage {
        case .known:
            UsageFormatter.currencyString(self.project.costEstimate.knownUSD, currencyCode: "USD")
        case .partial:
            UsageFormatter.currencyString(self.project.costEstimate.knownUSD, currencyCode: "USD") + "+"
        case .unavailable:
            L("codex_workspaces_cost_unavailable")
        }
    }

    private var accessibilityDescription: String {
        CodexWorkspaceProjectAccessibilityDescription.make(
            projectName: self.project.displayName,
            tokenText: UsageFormatter.tokenCountString(self.tokens),
            severity: self.project.severity,
            estimatedCostText: self.showsEstimatedCost
                ? L("codex_workspaces_estimated_cost_value", self.costText)
                : nil,
            session: (self.sessionCount, self.project.topModel))
    }
}

private struct CodexWorkspaceSelectionSurface<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        self.content
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.selected ? Color.accentColor.opacity(self.selectionOpacity) : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                self.selected ? Color.accentColor.opacity(0.28) : Color.clear,
                                lineWidth: 1)
                    }
            }
            .contentShape(.rect(cornerRadius: 6))
    }

    private var selectionOpacity: Double {
        self.controlActiveState == .key ? 0.14 : 0.08
    }
}

struct CodexWorkspaceStatusBar: View {
    let store: UsageStore

    var body: some View {
        if #available(macOS 26.0, *) {
            self.content
        } else {
            self.content.background(.bar)
        }
    }

    private var content: some View {
        HStack(spacing: 7) {
            if self.store.codexLocalProjectUsageRefreshInFlight {
                ProgressView().controlSize(.mini)
                Text(self.store.codexLocalProjectUsageProgressSubtitle ?? L("codex_workspaces_indexing_local_logs"))
            } else if let error = self.store.codexLocalProjectUsageError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).lineLimit(1)
            } else if let snapshot = self.store.codexLocalProjectUsageSnapshot {
                Image(systemName: snapshot.sourceStatus.isPartial
                    ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(snapshot.sourceStatus.isPartial ? Color.orange : Color.green)
                Text(L(
                    "codex_workspaces_indexed_files",
                    snapshot.updatedAt.formatted(.relative(presentation: .named)),
                    snapshot.indexedFileCount))
                    .lineLimit(1)
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                Text(L("codex_workspaces_no_local_usage"))
            }
            Spacer()
            Text(L("codex_workspaces_estimated_local_logs"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}
