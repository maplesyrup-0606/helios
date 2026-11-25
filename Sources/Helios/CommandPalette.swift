import SwiftUI

private let theme = Theme.current

/// ⌘K: fuzzy-search contexts and actions.
struct CommandPalette: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        var subtitle = ""
        var icon = "command"
        var context: WorkContext?
        var shortcut = ""
        /// Actions that open their own UI (sheets) shouldn't hand focus back to the terminal.
        var keepsFocus = false
        let run: @MainActor () -> Void
    }

    private var items: [Item] {
        var items: [Item] = model.contexts.enumerated().map { index, context in
            Item(id: "ctx-\(context.id)", title: context.name,
                 subtitle: context.summary,
                 context: context, shortcut: index < 9 ? "⌘\(index + 1)" : "") {
                withAnimation(.snappy(duration: 0.24)) { model.selectedID = context.id }
            }
        }
        items += [
            Item(id: "new", title: "New context", icon: "plus", shortcut: "⌘T", keepsFocus: true) { model.beginNew() },
            Item(id: "edit", title: "Edit context", icon: "slider.horizontal.3", shortcut: "⇧⌘E", keepsFocus: true) { model.beginEditSelected() },
            Item(id: "drawer", title: "Toggle drawer", icon: "rectangle.bottomthird.inset.filled", shortcut: "⌘I") { model.toggleDrawer() },
        ]
        for (index, tab) in DrawerTab.allCases.enumerated() where !tab.needsHost || model.selected?.hasHost == true {
            items.append(Item(id: "drawer-\(tab.rawValue)", title: "Show \(tab.rawValue)", icon: icon(for: tab),
                              keepsFocus: tab == .notes) {
                if model.drawerTab != tab { model.toggleDrawer(tab) }
            })
        }
        if let selected = model.selected {
            for side in PaneSide.allCases where selected[side].hasTerminal {
                let pane = selected[side]
                let key = side == .left ? "[" : "]"
                items += [
                    Item(id: "focus-\(side.rawValue)", title: "Focus \(side.rawValue) pane", subtitle: pane.location,
                         icon: pane.isSSH ? "network" : "laptopcomputer", shortcut: "⌘" + key, keepsFocus: true) {
                        model.focusPane(side)
                    },
                    Item(id: "\(side.rawValue)-tab", title: "New tab in \(side.rawValue) pane", subtitle: pane.location,
                         icon: "plus.rectangle.on.rectangle", keepsFocus: true) {
                        model.addTab(side)
                    },
                ]
            }
            if selected.hasHost {
                items.append(Item(id: "reconnect", title: "Reconnect SSH", icon: "arrow.triangle.2.circlepath") {
                    guard let runtime = model.existingRuntime(for: selected.id) else { return }
                    selected.sshSides.compactMap(runtime.visible).forEach { $0.refresh() }
                })
            }
        }
        items += [
            Item(id: "tab-next", title: "Next tab in focused pane", icon: "chevron.right", shortcut: "⇧⌘→", keepsFocus: true) {
                model.selectAdjacentTab(1)
            },
            Item(id: "tab-prev", title: "Previous tab in focused pane", icon: "chevron.left", shortcut: "⇧⌘←", keepsFocus: true) {
                model.selectAdjacentTab(-1)
            },
            Item(id: "tab-close", title: "Close tab in focused pane", subtitle: "Not available on a pane's first tab",
                 icon: "xmark.rectangle", shortcut: "⌘W", keepsFocus: true) { model.requestCloseCurrentTab() },
        ]
        items.append(Item(id: "restart", title: "Restart terminals", subtitle: "Reattaches tmux sessions",
                          icon: "arrow.clockwise", shortcut: "⇧⌘R") { model.restartSelected() })
        return items
    }

    private var results: [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item -> (Int, Int, Item)? in
                guard let score = fuzzyScore(trimmed, in: item.title + " " + item.subtitle) else { return nil }
                return (score, index, item)
            }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textFaint)
                    TextField("Jump to a context or run a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isFieldFocused)
                        .onSubmit { run(results) }
                    Text("esc").font(theme.mono(10)).foregroundStyle(theme.textFaint)
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                Rectangle().fill(theme.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isHighlighted: index == highlighted)
                                    .id(item.id)
                                    .onHover { if $0 { highlighted = index } }
                                    .onTapGesture { highlighted = index; run(results) }
                            }
                            if results.isEmpty {
                                Text("No matches").font(.system(size: 12)).foregroundStyle(theme.textFaint).padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: highlighted) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
            .frame(width: 580)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: theme.background.mixed(with: .black, 0.15)))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .padding(.top, 90)
        }
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onExitCommand(perform: close)
    }

    private func run(_ results: [Item]) {
        guard results.indices.contains(highlighted) else { return }
        let item = results[highlighted]
        model.isPaletteOpen = false
        item.run()
        if !item.keepsFocus { model.focusSelectedTerminal() }
    }

    private func close() {
        model.isPaletteOpen = false
        model.focusSelectedTerminal()
    }

    private func icon(for tab: DrawerTab) -> String {
        switch tab {
        case .jobs: "cpu"
        case .git: "arrow.triangle.branch"
        case .notes: "note.text"
        case .files: "folder"
        }
    }
}

private struct PaletteRow: View {
    let item: CommandPalette.Item
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let context = item.context {
                Monogram(context: context, ssh: nil, size: 24)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHighlighted ? theme.accent : theme.textMuted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.fill))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(theme.mono(10.5)).foregroundStyle(theme.textFaint).lineLimit(1)
                }
            }
            Spacer()
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(theme.mono(10.5)).foregroundStyle(theme.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? theme.fillStrong : .clear)
        )
        .contentShape(Rectangle())
    }
}

/// Subsequence match score (nil = no match); rewards word starts and consecutive runs.
func fuzzyScore(_ query: String, in text: String) -> Int? {
    let q = Array(query.lowercased()), t = Array(text.lowercased())
    var score = 0, qi = 0, run = 0
    var previous: Character = " "
    for ch in t {
        guard qi < q.count else { break }
        if ch == q[qi] {
            run += 1
            score += 1 + run * 2 + (previous == " " || previous == "-" || previous == "_" || previous == "/" ? 6 : 0)
            qi += 1
        } else {
            run = 0
        }
        previous = ch
    }
    return qi == q.count ? score : nil
}
