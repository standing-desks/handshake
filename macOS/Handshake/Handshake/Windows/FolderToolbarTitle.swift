import SwiftUI

/// The folder's name, then its path, or in the sidebar layout the selected session and tab, which no other
/// on-screen element names while the sidebar is minimized.
struct FolderToolbarTitle: View {
    @Environment(CoreClient.self) private var client
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.defaultValue
    @AppStorage(TabLayout.hintKey) private var showsHint = false
    let path: String
    /// The selected session's selected tab, from this window's own state so inactive windows show it too.
    var selectedReference: String?
    var selectedTitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(URL(filePath: path).lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .layoutPriority(1)
            subtitle
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .padding(.leading, 6)
        .frame(maxWidth: 320, alignment: .leading)
        .help(path)
        .onChange(of: selectedReference) { old, new in
            if old != nil && old != new { showsHint = false }
        }
        .onChange(of: tabLayout) { showsHint = false }
    }

    @ViewBuilder private var subtitle: some View {
        if tabLayout == .sidebar, showsHint {
            Label("Tabs moved to the sidebar · Right-click a tab to show them at the top", systemImage: "sidebar.left")
                .foregroundStyle(.tint)
                .accessibilityIdentifier("tabLayoutHint")
        } else if tabLayout == .sidebar, let session = client.snapshot?.workflows.session, session.folder == path {
            HStack(spacing: 5) {
                Text(session.name)
                if let selectedTitle {
                    Image(systemName: "chevron.forward").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text(selectedTitle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("folderBreadcrumb")
        } else {
            Text((path as NSString).abbreviatingWithTildeInPath)
        }
    }
}
