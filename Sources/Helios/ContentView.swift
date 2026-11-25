import AppKit
import SwiftUI

private let theme = Theme.current
/// Height of the top row; matches the hidden title bar so the traffic lights sit inside it.
private let headerHeight: CGFloat = 52
private let selectionAnimation = Animation.snappy(duration: 0.24)

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 232)
            Group {
                if model.selected != nil {
                    ZStack {
                        ForEach(model.mountedContexts, id: \.context.id) { context, runtime in
                            let isActive = context.id == model.selectedID
                            // Keyed by runtime so a restarted context rebuilds its panes.
                            ContextDetail(context: context, runtime: runtime, isActive: isActive)
                                .id(ObjectIdentifier(runtime))
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                                .accessibilityHidden(!isActive)
                        }
                    }
                    // Switch instantly; animating would re-lay-out terminals every frame.
                    .transaction { $0.animation = nil }
                } else {
                    EmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WindowGlass())
        .overlay {
            if model.isPaletteOpen {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.18), value: model.isPaletteOpen)
        .animation(.snappy(duration: 0.2), value: model.attention)
        .foregroundStyle(theme.text)
        .ignoresSafeArea()
        .alert(
            "Close “\(model.closingTab?.tab.name ?? "")”?",
            isPresented: Binding(get: { model.closingTab != nil }, set: { if !$0 { model.closingTab = nil } }),
            presenting: model.closingTab
        ) { closing in
            Button("Close Tab", role: .destructive) { model.closeTab(closing.tab, side: closing.side) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                model.closingTab = nil
                model.focusPane(closing.side)
            }
        } message: { closing in
            let pane = model.selected?[closing.side]
            Text(pane?.isSSH == true
                 ? "This ends its tmux session on \(pane?.trimmedHost ?? "the host") and anything running in it."
                 : "This ends its local tmux session and anything running in it.")
        }
        .sheet(item: $model.editing) { context in
            ContextEditor(draft: context, isNew: model.isNewContext)
                .environmentObject(model)
        }
    }
}

/// Frosted, theme-tinted window background; panes float above it as opaque cards.
private struct WindowGlass: View {
    var body: some View {
        ZStack {
            VisualEffect()
            theme.glassTint
        }
        .ignoresSafeArea()
    }

    private struct VisualEffect: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: headerHeight)
            HStack {
                Text("Contexts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textFaint)
                Spacer()
                Text("\(model.contexts.count)")
                    .font(theme.mono(10))
                    .foregroundStyle(theme.textFaint)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(model.contexts.enumerated()), id: \.element.id) { index, context in
                        SidebarRow(context: context, index: index,
                                   isSelected: context.id == model.selectedID,
                                   namespace: selection)
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            NewContextButton()
                .padding(12)
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let context: WorkContext
    let index: Int
    let isSelected: Bool
    let namespace: Namespace.ID
    @State private var isHovered = false

    private var subtitle: String {
        context.summary
    }

    var body: some View {
        HStack(spacing: 11) {
            Monogram(context: context, ssh: model.existingRuntime(for: context.id)?.primarySSH, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.text : theme.textMuted)
                    .lineLimit(1)
                Text(subtitle)
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let attention = model.attention[context.id] {
                AttentionBadge(kind: attention)
            } else if index < 9 && isHovered {
                Text("⌘\(index + 1)")
                    .font(theme.mono(10))
                    .foregroundStyle(theme.textFaint)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.fillStrong)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.fill)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .onTapGesture { withAnimation(selectionAnimation) { model.selectedID = context.id } }
        .contextMenu {
            Button("Edit…") { model.selectedID = context.id; model.beginEditSelected() }
            Button("Restart Terminals") { model.restart(context.id) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(context.id) }
        }
    }
}

/// Glowing dot on a background context: accent for a bell, green when Claude went quiet.
private struct AttentionBadge: View {
    let kind: ContextRuntime.Attention
    @State private var pulse = false

    var body: some View {
        let color = kind == .bell ? theme.accent : theme.ok
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.25 : 0.8)
                .opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .help(kind == .bell ? "Terminal bell" : "Finished — waiting for you")
        .transition(.scale.combined(with: .opacity))
    }
}

/// Rounded initial in the context's hue, with an SSH status dot in the corner.
struct Monogram: View {
    let context: WorkContext
    let ssh: TerminalSession?
    let size: CGFloat

    var body: some View {
        let hue = theme.hue(for: context.id)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [hue.opacity(0.32), hue.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(hue.opacity(0.35), lineWidth: 1))
            .overlay(
                Text(context.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                    .foregroundStyle(hue)
            )
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if context.hasHost {
                    StatusDot(ssh: ssh)
                        .offset(x: 3, y: 3)
                }
            }
    }
}

/// SSH health: hollow until the tab has been opened.
private struct StatusDot: View {
    let ssh: TerminalSession?

    var body: some View {
        if let ssh {
            LiveDot(session: ssh)
        } else {
            dot(fill: theme.textFaint.opacity(0.0), ring: theme.textFaint)
        }
    }

    private struct LiveDot: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            let color = color(for: session.state)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(nsColor: theme.background.mixed(with: .black, 0.35)), lineWidth: 2))
                .shadow(color: color.opacity(0.6), radius: 3)
        }
    }

    private func dot(fill: Color, ring: Color) -> some View {
        Circle()
            .fill(Color(nsColor: theme.background.mixed(with: .black, 0.35)))
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(ring, lineWidth: 1.5).padding(1))
    }
}

private func color(for state: TerminalSession.State) -> Color {
    switch state {
    case .running: theme.ok
    case .waiting: theme.warn
    case .ended: theme.textFaint
    case .failed: theme.error
    }
}

private struct NewContextButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var isHovered = false

    var body: some View {
        Button { model.beginNew() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("New context").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("⌘T").font(theme.mono(10)).foregroundStyle(theme.textFaint)
            }
            .foregroundStyle(isHovered ? theme.text : theme.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovered ? theme.fillStrong : theme.fill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
    }
}

// MARK: - Detail

private struct ContextDetail: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("drawerRatio") private var drawerRatio = 0.62
    let context: WorkContext
    @ObservedObject var runtime: ContextRuntime
    /// Only the selected context is visible; others stay mounted but hidden.
    let isActive: Bool

    private var drawerTab: DrawerTab? {
        guard isActive, let tab = model.drawerTab, !tab.needsHost || context.hasHost else { return nil }
        return tab
    }

    var body: some View {
        VStack(spacing: 0) {
            ContextHeader(context: context, runtime: runtime)
            ResizableSplit(axis: .vertical, ratio: drawerRatio, range: 0.25...0.85,
                           showsSecond: drawerTab != nil, onCommit: { drawerRatio = $0 }) {
                panes
            } second: {
                if let tab = drawerTab {
                    Drawer(context: context, runtime: runtime, tab: tab, sendToSSH: sendToSSH)
                }
            }
            .padding([.horizontal, .bottom], 10)
        }
        .onAppear { activate(isActive) }
        .onChange(of: isActive) { _, active in activate(active) }
        .onDisappear { runtime.setActive(false) }
    }

    /// Polling runs only for the visible context; becoming visible puts the cursor in its left pane.
    private func activate(_ active: Bool) {
        runtime.setActive(active)
        guard active else { return }
        let side: PaneSide = context.left.hasTerminal ? .left : .right
        if let session = runtime.visible(side) { FocusTracker.shared.request(session.terminal) }
    }

    private var panes: some View {
        ResizableSplit(axis: .horizontal, ratio: context.splitRatio,
                       onCommit: { ratio in model.update(context.id) { $0.splitRatio = ratio } }) {
            PaneView(side: .left, context: context, runtime: runtime, isActive: isActive)
        } second: {
            PaneView(side: .right, context: context, runtime: runtime, isActive: isActive)
        }
    }

    /// Types into the shell of the pane on the file browser's host.
    private func sendToSSH(_ text: String) {
        guard let side = context.primarySSHSide, let session = runtime.visible(side) else { return }
        session.terminal.send(data: ArraySlice(Array(text.utf8)))
        FocusTracker.shared.request(session.terminal)
    }
}

/// One pane: its sub-tabs in the card header plus the selected sub-tab's terminal, wherever it runs.
private struct PaneView: View {
    @EnvironmentObject private var model: AppModel
    let side: PaneSide
    let context: WorkContext
    @ObservedObject var runtime: ContextRuntime
    let isActive: Bool
    @ObservedObject private var focus = FocusTracker.shared

    private var pane: PaneConfig { context[side] }

    private var selectedTab: PaneTab? {
        pane.tabs.first { $0.id == runtime.selectedTab(side) } ?? pane.tabs.first
    }

    var body: some View {
        if !pane.hasTerminal {
            Card {
                HStack {
                    Image(systemName: pane.kind == .ssh ? "network.slash" : "rectangle.dashed")
                        .font(.system(size: 10)).foregroundStyle(theme.textFaint)
                    Text(side.label.lowercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 12)
            } content: {
                VStack(spacing: 8) {
                    Text(pane.kind == .ssh ? "No SSH host" : "No terminal")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textMuted)
                    Button("Set one up  ⇧⌘E") { model.beginEditSelected() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let selected = selectedTab {
            Card(isFocused: runtime.visible(side).map { focus.isFocused($0.terminal) } ?? false) {
                PaneTabStrip(side: side, context: context, runtime: runtime)
            } content: {
                // Every opened sub-tab stays mounted; switching only changes which is visible.
                ZStack {
                    ForEach(pane.tabs) { tab in
                        if let session = runtime.sessions[tab.id] {
                            let visible = isActive && tab.id == selected.id
                            TerminalSurface(view: session.terminal, isVisible: visible)
                                .opacity(visible ? 1 : 0)
                                .allowsHitTesting(visible)
                                // A restarted tab gets a new session; give it a fresh host.
                                .id(ObjectIdentifier(session))
                        }
                    }
                }
                .onAppear {
                    // A saved sub-tab starts the first time it's shown (outside view updates).
                    if runtime.sessions[selected.id] == nil { _ = runtime.session(for: selected, side: side) }
                }
            }
        }
    }
}

/// Card header for either pane: an icon, the sub-tab pills, and a + button.
private struct PaneTabStrip: View {
    @EnvironmentObject private var model: AppModel
    let side: PaneSide
    let context: WorkContext
    @ObservedObject var runtime: ContextRuntime
    @Namespace private var pill
    @State private var renaming: PaneTab?
    @State private var newName = ""

    private var tabs: [PaneTab] { context.tabs(side) }
    private var pane: PaneConfig { context[side] }
    private var selectedID: UUID? { runtime.selectedTab(side) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pane.isLocal ? "laptopcomputer" : "network")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textFaint)
                .padding(.leading, 4)
                .help(pane.location)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        PaneTabButton(
                            tab: tab,
                            session: runtime.sessions[tab.id],
                            isSelected: tab.id == selectedID,
                            canClose: index > 0,
                            namespace: pill,
                            select: { model.selectTab(tab, side: side) },
                            close: { model.requestCloseTab(tab, side: side) },
                            rename: { newName = tab.name; renaming = tab })
                    }
                }
            }
            IconButton(systemName: "plus", help: pane.isSSH ? "New tab on \(pane.trimmedHost) (⇧⌘T)" : "New local tab (⇧⌘T)") {
                model.addTab(side)
            }
        }
        .padding(.horizontal, 6)
        .alert("Rename tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let tab = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.renameTab(tab, side: side, to: newName)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

private struct PaneTabButton: View {
    let tab: PaneTab
    let session: TerminalSession?
    let isSelected: Bool
    let canClose: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    let rename: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let session, session.isRemote { SSHStateDot(session: session) }
            Text(tab.name)
                .font(theme.mono(11))
                .foregroundStyle(isSelected ? theme.text : theme.textMuted)
            if let session, !session.isRemote { LocalRestart(session: session) }
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textFaint)
                .opacity(isHovered ? 1 : 0)
                .help("Close tab and end its tmux session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                Capsule().fill(theme.fillStrong)
                    .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
                    .matchedGeometryEffect(id: "pill", in: namespace)
            } else if isHovered {
                Capsule().fill(theme.fill)
            }
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Rename…", action: rename)
            if canClose { Button("Close", role: .destructive, action: close) }
        }
    }

    private struct SSHStateDot: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            let c = color(for: session.state)
            Circle().fill(c).frame(width: 6, height: 6).shadow(color: c.opacity(0.7), radius: 2)
        }
    }

    /// Shown only when the tab's shell has exited.
    private struct LocalRestart: View {
        @ObservedObject var session: TerminalSession
        var body: some View {
            if session.state == .ended {
                Button("restart") { session.start() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
        }
    }
}

/// Top strip: context identity plus at-a-glance chips that open the matching drawer tab.
private struct ContextHeader: View {
    @EnvironmentObject private var model: AppModel
    let context: WorkContext
    @ObservedObject var runtime: ContextRuntime

    var body: some View {
        HStack(spacing: 8) {
            Monogram(context: context, ssh: nil, size: 22)
            Text(context.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
            GitChip(git: runtime.git) { toggle(.git) }
            ForEach(runtime.sshPrimaries, id: \.tab.id) { ssh in
                SSHChip(pane: context[ssh.side], session: ssh)
                    .layoutPriority(-1)
            }
            if let jobs = runtime.jobs {
                JobsChip(jobs: jobs) { toggle(.jobs) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if context.hasHost {
                    IconButton(systemName: "arrow.clockwise", help: "Refresh SSH panes") {
                        context.sshSides.compactMap(runtime.visible).forEach { $0.refresh() }
                    }
                }
                if context.hasHost {
                    IconButton(systemName: "folder", help: "Remote files", isActive: model.drawerTab == .files) {
                        toggle(.files)
                    }
                }
                IconButton(systemName: "note.text", help: "Notes", isActive: model.drawerTab == .notes) {
                    toggle(.notes)
                }
                IconButton(systemName: "rectangle.bottomthird.inset.filled", help: "Toggle drawer (⌘I)", isActive: model.drawerTab != nil) {
                    toggle(nil)
                }
                IconButton(systemName: "slider.horizontal.3", help: "Edit context (⇧⌘E)") {
                    model.beginEditSelected()
                }
            }
            .padding(3)
            .background(Capsule().fill(theme.fill))
            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
    }

    private func toggle(_ tab: DrawerTab?) {
        withAnimation(.snappy(duration: 0.28)) { model.toggleDrawer(tab) }
    }
}

private struct GitChip: View {
    @ObservedObject var git: GitMonitor
    let action: () -> Void

    var body: some View {
        if git.isRepo || git.remote != nil {
            Button(action: action) {
                Chip(icon: "arrow.triangle.branch") {
                    if git.isRepo {
                        Text(git.branch)
                        if !git.changes.isEmpty {
                            Text("±\(git.changes.count)").foregroundStyle(theme.warn)
                        }
                        if !git.tracking.isEmpty {
                            Text(Self.arrows(git.tracking)).foregroundStyle(theme.textFaint)
                        }
                    }
                    if let remote = git.remote {
                        if git.isRepo { Text("·").foregroundStyle(theme.textFaint) }
                        Image(systemName: "server.rack").font(.system(size: 9)).foregroundStyle(theme.textFaint)
                        // Highlighted when the cluster checkout is on a different branch than local.
                        Text(remote.branch)
                            .foregroundStyle(git.isRepo && remote.branch != git.branch ? theme.warn : theme.text)
                        if remote.changeCount > 0 {
                            Text("±\(remote.changeCount)").foregroundStyle(theme.warn)
                        }
                        if !remote.tracking.isEmpty {
                            Text(Self.arrows(remote.tracking)).foregroundStyle(theme.textFaint)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help(helpText)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if git.isRepo { parts.append("Local: \(git.branch)") }
        if let remote = git.remote { parts.append("\(git.host ?? "Remote"): \(remote.branch)") }
        return parts.joined(separator: " · ")
    }

    static func arrows(_ tracking: String) -> String {
        tracking.replacingOccurrences(of: "ahead ", with: "↑").replacingOccurrences(of: "behind ", with: "↓")
    }
}

private struct JobsChip: View {
    @ObservedObject var jobs: JobsMonitor
    let action: () -> Void

    var body: some View {
        if jobs.status == .ok {
            Button(action: action) {
                Chip(icon: "cpu") {
                    if jobs.jobs.isEmpty {
                        Text("no jobs")
                    } else {
                        if jobs.runningCount > 0 { Text("\(jobs.runningCount) R").foregroundStyle(theme.ok) }
                        if jobs.pendingCount > 0 { Text("\(jobs.pendingCount) PD").foregroundStyle(theme.warn) }
                        let other = jobs.jobs.count - jobs.runningCount - jobs.pendingCount
                        if other > 0 { Text("\(other) other") }
                        if let p = jobs.jobs.lazy.compactMap({ jobs.progress[$0.id] }).first {
                            ProgressBar(fraction: p.fraction).frame(width: 34, height: 4)
                            Text("\(Int((p.fraction * 100).rounded()))%").foregroundStyle(theme.accent)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("SLURM jobs")
        }
    }
}

private struct Chip<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textFaint)
            content
        }
        .font(theme.mono(11))
        .foregroundStyle(theme.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(isHovered ? theme.fillStrong : theme.fill))
        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
        .lineLimit(1)
        .onHover { isHovered = $0 }
    }
}

private struct SSHChip: View {
    let pane: PaneConfig
    @ObservedObject var session: TerminalSession

    var body: some View {
        Chip(icon: "network") {
            let c = color(for: session.state)
            Circle().fill(c).frame(width: 6, height: 6).shadow(color: c.opacity(0.7), radius: 2)
            Text(pane.trimmedHost)
            switch session.state {
            case .running:
                EmptyView()
            case let .waiting(_, retryAt):
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text("retry \(max(0, Int(retryAt.timeIntervalSince(timeline.date).rounded(.up))))s")
                        .foregroundStyle(theme.warn)
                }
                ChipAction(title: "now") { session.reconnectNow() }
            case .ended, .failed:
                ChipAction(title: "reconnect") { session.reconnectNow() }
            }
        }
        .help(pane.location)
    }
}

private struct ChipAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal hosting

/// Inset terminal inside a card.
private struct TerminalSurface: View {
    let view: NSView
    let isVisible: Bool

    var body: some View {
        TerminalHost(view: view, isVisible: isVisible)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
    }
}

/// Tracks the window's first responder so the focused pane can be highlighted.
@MainActor
final class FocusTracker: ObservableObject {
    static let shared = FocusTracker()
    @Published private(set) var focused: ObjectIdentifier?
    /// The focused view itself, for working out which pane it belongs to.
    private(set) weak var focusedView: NSView?
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func watch(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard observations[key] == nil else { return }
        observations[key] = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            let responderView = window.firstResponder as? NSView
            let responder = window.firstResponder.map(ObjectIdentifier.init)
            // Deliver on the next tick: first-responder changes can happen inside SwiftUI view
            // updates, and publishing there is undefined behavior (stale/missed redraws).
            DispatchQueue.main.async {
                self?.focusedView = responderView
                self?.focused = responder
            }
        }
    }

    func isFocused(_ view: NSView) -> Bool { focused == ObjectIdentifier(view) }

    /// A terminal that should take keyboard focus as soon as it is on screen.
    private weak var pending: NSView?

    /// Focuses `view` now if it's in a window, otherwise as soon as it gets attached
    /// (e.g. a sub-tab that SwiftUI hasn't swapped in yet).
    func request(_ view: NSView) {
        pending = view
        // Wait a tick so SwiftUI finishes swapping views (and tearing down e.g. the palette field).
        DispatchQueue.main.async { [weak self, weak view] in
            if let view { self?.attached(view) }
        }
    }

    /// Called by terminal hosts whenever a terminal lands in a window.
    func attached(_ view: NSView) {
        guard pending === view, let window = view.window else { return }
        pending = nil
        window.makeFirstResponder(view)
    }
}

/// Which container currently owns each terminal view. SwiftUI can briefly keep an old and a
/// new host alive during a tab switch; only the newest claimant may hold the view, otherwise
/// the outgoing host steals it back and takes it with it when torn down (blank pane).
@MainActor
private enum TerminalOwnership {
    static let owners = NSMapTable<NSView, NSView>.weakToWeakObjects()
}

/// Sizes its terminal manually instead of with constraints. A freshly created host starts at zero
/// size; letting the terminal follow that would resize the pty twice per tab switch, and each
/// resize makes tmux and Claude redraw everything (slow for long conversations). The terminal
/// only adopts a size once the container has a real one, and only when it actually changes.
private final class TerminalContainer: NSView {
    weak var hosted: NSView?
    private static let minimumSide: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        FocusTracker.shared.watch(window)
        let views = subviews
        DispatchQueue.main.async { views.forEach { FocusTracker.shared.attached($0) } }
    }

    override func layout() {
        super.layout()
        applyFrame()
    }

    func applyFrame() {
        guard let hosted, hosted.superview === self,
              bounds.width >= Self.minimumSide, bounds.height >= Self.minimumSide,
              hosted.frame != bounds else { return }
        hosted.frame = bounds
    }
}

/// Hosts a long-lived terminal NSView; the view is re-parented, never recreated,
/// so processes and scrollback survive tab switches.
private struct TerminalHost: NSViewRepresentable {
    let view: NSView
    let isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer(frame: .zero)
        container.isHidden = !isVisible
        claim(for: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.isHidden == isVisible { container.isHidden = !isVisible }
        let owner = TerminalOwnership.owners.object(forKey: view)
        // Re-attach only if this host owns the view, or the owner is gone/offscreen.
        guard owner === container || owner == nil || owner?.window == nil else { return }
        if view.superview !== container { claim(for: container) }
    }

    private func claim(for container: NSView) {
        TerminalOwnership.owners.setObject(container, forKey: view)
        // Removing from the old host drops its constraints; keep the terminal's current frame
        // until the new host has a real size (see TerminalContainer).
        let frame = view.frame
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        view.frame = frame
        container.addSubview(view)
        (container as? TerminalContainer)?.hosted = view
        (container as? TerminalContainer)?.applyFrame()
        view.needsDisplay = true
        if container.window != nil {
            DispatchQueue.main.async { [view] in FocusTracker.shared.attached(view) }
        }
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(theme.accent.opacity(0.25)).frame(width: 90, height: 90).blur(radius: 30)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.accent)
            }
            Text("No contexts yet").font(.system(size: 17, weight: .semibold))
            Text("A context pairs two terminals, each on this Mac or any SSH host.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
            Button("New context  ⌘T") { model.beginNew() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.background.isDark ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(theme.accent))
                .shadow(color: theme.accent.opacity(0.4), radius: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension NSColor {
    var isDark: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }
}

// MARK: - Editor

private struct ContextEditor: View {
    @EnvironmentObject private var model: AppModel
    @State var draft: WorkContext
    let isNew: Bool
    @State private var leftChoice: ConversationChoice
    @State private var rightChoice: ConversationChoice
    private let leftPin: String?
    private let rightPin: String?

    init(draft: WorkContext, isNew: Bool) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        func choice(_ side: PaneSide) -> ConversationChoice {
            let pinned = isNew ? nil : ClaudePins.shared[draft.id, side]
            return ConversationChoice(original: pinned, picked: pinned)
        }
        leftPin = isNew ? nil : ClaudePins.shared[draft.id, .left]
        rightPin = isNew ? nil : ClaudePins.shared[draft.id, .right]
        _leftChoice = State(initialValue: choice(.left))
        _rightChoice = State(initialValue: choice(.right))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New context" : "Edit context").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Name", text: $draft.name)
                PaneEditor(side: .left, pane: $draft.left, choice: $leftChoice,
                           saved: savedPane(.left), pinned: leftPin, isNew: isNew)
                PaneEditor(side: .right, pane: $draft.right, choice: $rightChoice,
                           saved: savedPane(.right), pinned: rightPin, isNew: isNew)
                Section {
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { model.delete(draft.id) }
                }
                Spacer()
                Button("Cancel") { model.editing = nil }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 680)
        .background(theme.canvas)
    }

    private func savedPane(_ side: PaneSide) -> PaneConfig? {
        isNew ? nil : model.contexts.first(where: { $0.id == draft.id })?[side]
    }

    private var footnote: String {
        let restarts = PaneSide.allCases.filter { side in
            guard let saved = savedPane(side) else { return false }
            return saved.launchTarget != draft[side].launchTarget
        }
        if !restarts.isEmpty {
            return "Saving moves the \(restarts.map { $0.label.lowercased() }.joined(separator: " and ")) pane: its tmux sessions there are ended and fresh ones start in the new place."
        }
        if leftChoice.changed(draft.left) || rightChoice.changed(draft.right) {
            return "Saving restarts the Claude tab in the chosen conversation."
        }
        return "Each pane runs on this Mac or any SSH host. The startup command runs in the pane's first tab only when Helios creates a new session (first open, after a reboot, or after the shell exits); otherwise Helios reattaches to what's already running. With resume on, a plain `claude` reopens that pane's own conversation, which Helios follows as it changes (including /resume inside the tab), locally or on the host."
    }

    private func save() {
        var conversations: [PaneSide: String] = [:]
        for (side, choice) in [(PaneSide.left, leftChoice), (.right, rightChoice)] {
            guard choice.changed(draft[side]), let picked = choice.picked else { continue }
            conversations[side] = picked == ConversationChoice.new ? UUID().uuidString.lowercased() : picked
        }
        model.commit(draft, conversations: conversations)
    }
}

/// The Claude conversation picker's state for one pane.
private struct ConversationChoice {
    static let new = "new"
    /// Conversations in the pane's folder, newest first.
    var list: [ClaudeHistory.Conversation] = []
    /// The pinned conversation when the editor opened, and the one picked now.
    var original: String?
    var picked: String?

    func changed(_ pane: PaneConfig) -> Bool {
        pane.isLocal && pane.resumeConversation && picked != original
    }
}

/// Where one pane runs and what it starts with.
private struct PaneEditor: View {
    let side: PaneSide
    @Binding var pane: PaneConfig
    @Binding var choice: ConversationChoice
    /// The pane as saved, to tell when its folder changed; nil for a new context.
    let saved: PaneConfig?
    /// The pane's pinned conversation when the editor opened.
    let pinned: String?
    let isNew: Bool
    private let knownHosts = SSHConfig.hosts()

    var body: some View {
        Section("\(side.label) pane") {
            Picker("Runs on", selection: $pane.kind) {
                Text("This Mac").tag(PaneKind.local)
                Text("SSH host").tag(PaneKind.ssh)
                Text("Nothing").tag(PaneKind.none)
            }
            .pickerStyle(.segmented)
            if pane.kind == .ssh {
                HStack {
                    TextField("Host", text: $pane.host, prompt: Text("alias from ~/.ssh/config, or user@host"))
                    if !knownHosts.isEmpty {
                        Menu("Hosts") {
                            ForEach(knownHosts, id: \.self) { host in
                                Button(host) { pane.host = host }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            if pane.kind != .none {
                HStack {
                    TextField("Directory", text: $pane.dir,
                              prompt: Text(pane.kind == .ssh ? "~/scratch/project (optional)" : "~"))
                    if pane.kind == .local { Button("Choose…", action: chooseDirectory) }
                }
                TextField("Startup command", text: $pane.startupCommand, prompt: Text("none — e.g. claude"))
                if isClaude {
                    Toggle("Resume this pane's Claude conversation", isOn: $pane.resumeConversation)
                    if pane.resumeConversation && pane.kind == .local {
                        Picker("Conversation", selection: $choice.picked) {
                            if choice.original == nil {
                                Text("Most recent in this folder").tag(String?.none)
                            } else if !choice.list.contains(where: { $0.id == choice.original }) {
                                Text("Current (no messages yet)").tag(choice.original)
                            }
                            ForEach(choice.list) { c in
                                Text(label(c)).tag(Optional(c.id))
                            }
                            Divider()
                            Text("New conversation").tag(Optional(ConversationChoice.new))
                        }
                    }
                }
            }
        }
        .task(id: pane.launchTarget) { await loadConversations() }
    }

    private var isClaude: Bool {
        pane.startupCommand.trimmingCharacters(in: .whitespaces).split(separator: " ").first == "claude"
    }

    private func label(_ c: ClaudeHistory.Conversation) -> String {
        let when = c.modified.formatted(.relative(presentation: .named))
        return (c.title.isEmpty ? String(c.id.prefix(8)) : c.title) + " · " + when
    }

    private func loadConversations() async {
        let target = pane.launchTarget
        // A different place has different conversations; the pin no longer applies there.
        if !isNew, let saved, saved.launchTarget != target {
            choice.original = nil
            if choice.picked != ConversationChoice.new { choice.picked = nil }
        } else if choice.original != pinned {
            // Back to the saved place: its pin applies again.
            choice.original = pinned
            choice.picked = pinned
        }
        guard pane.isLocal else {
            choice.list = []
            return
        }
        let dir = pane.dir
        let loaded = await Task.detached(priority: .userInitiated) {
            ClaudeHistory.conversations(in: dir).prefix(30).map { c -> ClaudeHistory.Conversation in
                var c = c
                c.title = ClaudeHistory.title(of: c.id, in: dir)
                return c
            }
        }.value
        guard target == pane.launchTarget else { return }
        choice.list = loaded
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: expandTilde(pane.dir.isEmpty ? "~" : pane.dir))
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            pane.dir = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }
}
