import SwiftUI

struct WorkspaceTabSwitcher: View {
    let items: [WorkspaceTabItem]
    let selected: String?
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var focusedID: String?
    @FocusState private var searchFocused: Bool

    private var matches: [WorkspaceTabItem] {
        items.filter { query.isEmpty || "\($0.title) \($0.detail) \($0.status ?? "")".localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Find an open tab…", text: $query)
                .textFieldStyle(.roundedBorder).padding(12)
                .focused($searchFocused)
                .accessibilityIdentifier("tabSwitcherSearch")
                .onChange(of: query) { focusedID = query.isEmpty ? selected ?? matches.first?.id : matches.first?.id }
                .onSubmit { if let id = focusedID ?? matches.first?.id { choose(id) } }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(matches) { item in
                            Button {
                                choose(item.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.pinned ? "pin.fill" : item.symbol).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let status = item.status {
                                        Text(status).font(.caption).foregroundStyle(item.statusColor)
                                    }
                                    if item.id == selected { Image(systemName: "checkmark") }
                                }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    item.id == focusedID ? Color.accentColor.opacity(0.15) : .clear,
                                    in: .rect(cornerRadius: 6)
                                )
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain).id(item.id)
                            .accessibilityIdentifier("switchTo-\(item.accessibilityID)")
                            .accessibilityValue(item.id == focusedID ? "Highlighted" : "")
                        }
                        if matches.isEmpty { Text("No matching tabs").foregroundStyle(.secondary).padding(24) }
                    }.padding(8)
                }
                .onChange(of: focusedID) { if let focusedID { proxy.scrollTo(focusedID) } }
            }
        }
        .frame(width: 480, height: 340)
        .defaultFocus($searchFocused, true)
        .onAppear {
            query = ""
            focusedID = selected ?? matches.first?.id
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onExitCommand { dismiss() }
    }

    private func choose(_ id: String) {
        select(id)
        dismiss()
    }

    private func move(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == focusedID } ?? 0
        focusedID = matches[(index + offset + matches.count) % matches.count].id
    }
}
