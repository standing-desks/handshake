import Foundation
import SwiftUI

struct FolderSidebar: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(FileTabsModel.self) private var fileTabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.defaultValue
    let path: String
    @Bindable var files: FileBrowserModel
    @Bindable var memories: MemoryModel
    let tabManagement: WorkspaceTabsModel
    @Binding var selection: WorkflowTabSelection
    @Bindable var presentation: SidebarPresentation
    /// The minimized sidebar's rail: sessions and their tabs as icons.
    var compact = false
    private var sessions: [CoreSession] {
        coreClient.snapshot?.workflows.sessions.filter { $0.folder == path } ?? []
    }
    private var selectedSession: CoreSession? { coreClient.snapshot?.workflows.session }

    var body: some View {
        Group {
            if compact { rail } else { sections }
        }
    }

    private var sections: some View {
        GeometryReader { geometry in
            let contentHeight = max(geometry.size.height, SidebarLayout.minimumContentHeight)
            let availableHeight = contentHeight - 3 * SidebarLayout.sectionHeaderHeight - 2
            // Sessions are the sidebar layout's navigation, so they get more of the height.
            let sessionsShare: CGFloat =
                switch (presentation.isSessionsExpanded, presentation.isFilesExpanded) {
                case (true, true): tabLayout == .sidebar ? 0.6 : 0.5
                case (true, false): 1
                default: 0
                }
            let filesHeight = availableHeight * (presentation.isFilesExpanded ? 1 - sessionsShare : 0)
            ScrollView {
                VStack(spacing: 0) {
                    // The sidebar layout puts its navigation first; the top layout keeps Files first.
                    if tabLayout == .sidebar {
                        sessionsSection(height: availableHeight * sessionsShare)
                        filesSection(height: filesHeight)
                    } else {
                        filesSection(height: filesHeight)
                        sessionsSection(height: availableHeight * sessionsShare)
                    }
                    MemorySidebar(model: memories, folder: path, contentHeight: availableHeight) {
                        guard let source = memories.selected else { return }
                        let request = memories.request(folder: path, sourceID: source.id)
                        Task {
                            do { try await fileTabs.openMemory(request: request, client: coreClient) } catch {
                                memories.openFailure = error.localizedDescription
                            }
                        }
                    }
                }
                .frame(height: contentHeight, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("sidebarViewport")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    @ViewBuilder private func sessionsSection(height: CGFloat) -> some View {
        sectionHeader("Sessions", isExpanded: $presentation.isSessionsExpanded) {
            Button(action: create) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).help("New Session")
            .accessibilityLabel("New Session").accessibilityIdentifier("newSession")
        }
        SectionViewport(isExpanded: presentation.isSessionsExpanded && !memories.isExpanded, height: height) {
            ScrollView {
                sessionList.padding(.horizontal, SidebarLayout.contentInset)
            }
        }
        Divider().frame(height: 1).padding(.horizontal, SidebarLayout.contentInset)
    }

    @ViewBuilder private func filesSection(height: CGFloat) -> some View {
        sectionHeader("Files", isExpanded: $presentation.isFilesExpanded) { EmptyView() }
        SectionViewport(isExpanded: presentation.isFilesExpanded && !memories.isExpanded, height: height) {
            FileTree(folder: path, model: files)
        }
        Divider().frame(height: 1).padding(.horizontal, SidebarLayout.contentInset)
    }

    /// The rail keeps the full sidebar's row heights, so each icon stays put when the rail widens.
    private var rail: some View {
        VStack(spacing: 0) {
            Button(action: create) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: SidebarLayout.sectionHeaderHeight).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("New Session")
            .accessibilityLabel("New Session").accessibilityIdentifier("railNewSession")
            ScrollView {
                outline(compact: true).padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
        .accessibilityIdentifier("sidebarRail")
    }

    @ViewBuilder private var sessionList: some View {
        if tabLayout == .sidebar {
            outline(compact: false)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: fileTabs.selected == nil && selectedSession?.id == session.id,
                        monogram: SessionMonogram.letters(for: session.name, among: sessions.map(\.name)),
                        select: {
                            // Another session restores its own selection once its tabs are prepared.
                            if session.id == selectedSession?.id {
                                fileTabs.contentSelection.showSession()
                            } else {
                                presentation.run { try await coreClient.selectSession(sessionID: session.id) }
                            }
                        },
                        rename: { presentation.sessionToRename = session },
                        delete: { presentation.sessionToDelete = session })
                }
            }
        }
    }

    private func outline(compact: Bool) -> some View {
        SessionOutline(
            folder: path, sessions: sessions, selectedSession: selectedSession?.id, model: tabManagement,
            selection: $selection, presentation: presentation, compact: compact)
    }

    private func sectionHeader<Actions: View>(
        _ title: String, isExpanded: Binding<Bool>, @ViewBuilder actions: () -> Actions
    ) -> some View {
        let expanded = isExpanded.wrappedValue && !memories.isExpanded
        return HStack {
            Button {
                withAnimation(reduceMotion ? nil : Motion.sectionToggle) {
                    if memories.isExpanded {
                        memories.isExpanded = false
                        isExpanded.wrappedValue = true
                    } else {
                        isExpanded.wrappedValue.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).sidebarSectionLabelStyle()
                    Spacer(minLength: 0)
                }
                .frame(height: SidebarLayout.sectionHeaderHeight).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("sidebarSection-\(title.lowercased())")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help("\(expanded ? "Collapse" : "Expand") \(title)")
            actions()
        }
        .frame(height: SidebarLayout.sectionHeaderHeight)
        .padding(.horizontal, SidebarLayout.sectionHeaderPadding)
    }

    private func create() {
        let name = "Session \(sessions.count + 1)"
        presentation.run {
            _ = try await coreClient.createSession(folder: path, name: name)
            withAnimation(reduceMotion ? nil : Motion.sectionToggle) {
                presentation.isSessionsExpanded = true
                memories.isExpanded = false
            }
            fileTabs.contentSelection.showSession()
        }
    }
}
