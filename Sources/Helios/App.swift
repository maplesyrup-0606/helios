import AppKit
import SwiftUI
import UserNotifications

enum DrawerTab: String, CaseIterable, Identifiable {
    case jobs = "Jobs", git = "Git", notes = "Notes", files = "Files"
    var id: String { rawValue }
    var needsHost: Bool { self == .jobs || self == .files }
}

/// App-wide state: saved contexts, the selected tab, and the live terminals per context.
@MainActor
final class AppModel: ObservableObject {
    let store = ContextStore()
    @Published var selectedID: UUID? {
        didSet {
            guard let selectedID else { return }
            clearAttention(selectedID)
            ensureRuntime(for: selectedID)
        }
    }
    /// Background contexts that want attention (bell, or Claude went quiet).
    @Published private(set) var attention: [UUID: ContextRuntime.Attention] = [:]
    @Published var isPaletteOpen = false
    /// Sub-tab awaiting close confirmation (closing kills its tmux session).
    @Published var closingTab: ClosingTab?

    struct ClosingTab: Identifiable {
        let tab: PaneTab
        let side: PaneSide
        var id: UUID { tab.id }
    }
    /// Context being edited in the sheet; `isNewContext` distinguishes add from edit.
    @Published var editing: WorkContext?
    @Published var isNewContext = false
    /// Open drawer tab under the terminals; nil when the drawer is closed.
    @Published var drawerTab: DrawerTab?
    private var runtimes: [UUID: ContextRuntime] = [:]
    private var claudeSync: Timer?

    init() {
        selectedID = store.contexts.first?.id
        // Track which conversation each Claude tab is in, so a fresh start (after a reboot)
        // resumes that one. Runs before any session starts, while old tmux sessions still hold
        // their Claude.
        ClaudePins.shared.sync(store.contexts)
        claudeSync = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                ClaudePins.shared.sync(self.store.contexts)
                await ClaudePins.shared.syncRemote(self.store.contexts)
            }
        }
        // Observers don't fire during init; start the first context once the app is running.
        DispatchQueue.main.async { [weak self] in
            if let id = self?.selectedID { self?.ensureRuntime(for: id) }
        }
    }

    var contexts: [WorkContext] { store.contexts }
    var selected: WorkContext? { store.contexts.first { $0.id == selectedID } }

    /// Starts a context's terminals the first time it is selected. Never call this from a view
    /// body: starting sessions runs processes and must happen outside SwiftUI updates.
    private func ensureRuntime(for id: UUID) {
        guard runtimes[id] == nil, let context = store.contexts.first(where: { $0.id == id }) else { return }
        let runtime = ContextRuntime(context: context)
        runtime.onAttention = { [weak self] kind in self?.flag(id, kind) }
        objectWillChange.send()
        runtimes[id] = runtime
    }

    /// Contexts whose panes stay mounted: every one opened so far.
    /// Switching only toggles visibility, so terminals are never torn down or re-inserted.
    var mountedContexts: [(context: WorkContext, runtime: ContextRuntime)] {
        store.contexts.compactMap { context in runtimes[context.id].map { (context, $0) } }
    }

    /// Runtime only if the tab has been opened (used for sidebar status without starting sessions).
    func existingRuntime(for id: UUID) -> ContextRuntime? { runtimes[id] }

    func select(index: Int) {
        guard store.contexts.indices.contains(index) else { return }
        withAnimation(.snappy(duration: 0.24)) { selectedID = store.contexts[index].id }
    }

    func selectAdjacent(_ offset: Int) {
        guard !store.contexts.isEmpty else { return }
        let current = store.contexts.firstIndex { $0.id == selectedID } ?? 0
        let count = store.contexts.count
        select(index: (current + offset + count) % count)
    }

    func beginNew() {
        isNewContext = true
        editing = WorkContext(name: "Context \(store.contexts.count + 1)", localDir: "~")
    }

    func beginEditSelected() {
        guard let selected else { return }
        isNewContext = false
        editing = selected
    }

    /// Saves an edited context. `conversations` holds, per pane, the Claude conversation its
    /// primary tab should be in; a change restarts that tab into it.
    func commit(_ context: WorkContext, conversations: [PaneSide: String] = [:]) {
        objectWillChange.send()
        guard let index = store.contexts.firstIndex(where: { $0.id == context.id }) else {
            for (side, id) in conversations { ClaudePins.shared[context.id, side] = id }
            store.contexts.append(context)
            selectedID = context.id
            editing = nil
            return
        }
        let old = store.contexts[index]
        store.contexts[index] = context
        // Panes now pointed somewhere else (another machine or folder) need fresh tmux sessions;
        // conversations belong to a folder, so those start without a pin.
        let moved = PaneSide.allCases.filter { old[$0].launchTarget != context[$0].launchTarget }
        for side in moved { ClaudePins.shared[context.id, side] = nil }
        var switched: [PaneSide] = []
        for (side, id) in conversations where !moved.contains(side) {
            if id != ClaudePins.shared[context.id, side] { switched.append(side) }
            ClaudePins.shared[context.id, side] = id
        }
        for (side, id) in conversations where moved.contains(side) { ClaudePins.shared[context.id, side] = id }
        // The startup command only applies to newly created sessions, so editing it never
        // interrupts a running one.
        if !moved.isEmpty {
            runtimes.removeValue(forKey: context.id)?.shutdown()
            let id = context.id
            Task {
                for side in moved { await PaneTmux.kill(old, side) }
                self.restart(id)
            }
        } else {
            runtimes[context.id]?.update(context)
            for side in switched { restartClaude(context, side) }
        }
        selectedID = context.id
        editing = nil
    }

    func delete(_ id: UUID) {
        objectWillChange.send()
        runtimes.removeValue(forKey: id)?.shutdown()
        // Remote tmux sessions are left running (they may hold jobs); local ones end with the context.
        if let context = store.contexts.first(where: { $0.id == id }) { PaneTmux.killLocal(context) }
        ClaudePins.shared.removeAll(for: id)
        clearAttention(id)
        store.contexts.removeAll { $0.id == id }
        if selectedID == id { selectedID = store.contexts.first?.id }
        editing = nil
    }

    func restart(_ id: UUID) {
        objectWillChange.send()
        runtimes.removeValue(forKey: id)?.shutdown()
        if id == selectedID { ensureRuntime(for: id) }
    }

    /// Restarts a pane's primary tab so Claude opens the pinned conversation. Without a
    /// runtime, the leftover tmux session is killed so the next open starts fresh.
    private func restartClaude(_ context: WorkContext, _ side: PaneSide) {
        if let runtime = runtimes[context.id] {
            Task { await runtime.restartPrimary(side) }
        } else if let tab = context[side].tabs.first {
            Task { await PaneTmux.kill(context, side, tabs: [tab]) }
        }
    }

    func restartSelected() {
        if let id = selectedID { restart(id) }
    }

    /// Saves a change that doesn't need terminals restarted (notes, split ratio, sub-tabs).
    func update(_ id: UUID, _ change: (inout WorkContext) -> Void) {
        guard let index = store.contexts.firstIndex(where: { $0.id == id }) else { return }
        objectWillChange.send()
        change(&store.contexts[index])
        runtimes[id]?.update(store.contexts[index])
    }

    // MARK: Attention

    private func flag(_ id: UUID, _ kind: ContextRuntime.Attention) {
        // The context on screen in the active app is already being looked at.
        if id == selectedID && NSApp.isActive { return }
        if let existing = attention[id], existing >= kind { return }
        attention[id] = kind
        updateDockBadge()
        guard !NSApp.isActive, let context = store.contexts.first(where: { $0.id == id }) else { return }
        NSApp.requestUserAttention(.informationalRequest)
        Notifier.post(title: context.name, body: kind == .bell ? "Terminal bell" : "Finished — waiting for you")
    }

    func clearAttention(_ id: UUID) {
        guard attention[id] != nil else { return }
        attention[id] = nil
        updateDockBadge()
    }

    /// When the app comes back to the front, the visible context counts as seen.
    func appDidBecomeActive() {
        if let selectedID { clearAttention(selectedID) }
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = attention.isEmpty ? nil : "\(attention.count)"
    }

    /// Returns keyboard focus to the selected context's left terminal (or the right, if the
    /// left pane has none).
    func focusSelectedTerminal() {
        guard let selected else { return }
        focusPane(selected.left.hasTerminal ? .left : .right)
    }

    /// Moves keyboard focus to the visible terminal of a pane.
    func focusPane(_ side: PaneSide) {
        guard let selected, let runtime = runtimes[selected.id] else { return }
        if let target = runtime.visible(side)?.terminal { FocusTracker.shared.request(target) }
    }

    func toggleDrawer(_ tab: DrawerTab? = nil) {
        let target = tab ?? drawerTab ?? (selected?.hasHost == true ? .jobs : .git)
        withAnimation(.snappy(duration: 0.28)) { drawerTab = drawerTab == target ? nil : target }
    }

    // MARK: Sub-tabs

    /// The pane holding keyboard focus; tab shortcuts act on it. Defaults to the left.
    func focusedSide() -> PaneSide {
        guard let selected, let runtime = runtimes[selected.id],
              let focused = FocusTracker.shared.focusedView else { return .left }
        return runtime.side(of: focused) ?? .left
    }

    private func selectTab(_ tab: PaneTab, side: PaneSide, in runtime: ContextRuntime) {
        runtime.select(tab.id, side: side)
        if let session = runtime.session(for: tab, side: side) { FocusTracker.shared.request(session.terminal) }
    }

    /// ⇧⌘T: new sub-tab in the focused pane, focused and ready to type.
    func addTab(_ side: PaneSide? = nil) {
        guard let context = selected, let runtime = runtimes[context.id] else { return }
        var side = side ?? focusedSide()
        if !context[side].hasTerminal { side = side.other }
        guard context[side].hasTerminal else { return }
        let tab = PaneTab(name: "shell \(context.tabs(side).count + 1)")
        update(context.id) { $0.setTabs(side, $0.tabs(side) + [tab]) }
        selectTab(tab, side: side, in: runtime)
    }

    /// ⇧⌘← / ⇧⌘→: previous/next sub-tab in the focused pane (wraps).
    func selectAdjacentTab(_ offset: Int, side: PaneSide? = nil) {
        guard let context = selected, let runtime = runtimes[context.id] else { return }
        let side = side ?? focusedSide()
        let tabs = context.tabs(side)
        let current = tabs.firstIndex { $0.id == runtime.selectedTab(side) } ?? 0
        guard !tabs.isEmpty else { return }
        selectTab(tabs[(current + offset + tabs.count) % tabs.count], side: side, in: runtime)
    }

    func selectTab(_ tab: PaneTab, side: PaneSide) {
        guard let context = selected, let runtime = runtimes[context.id] else { return }
        withAnimation(.snappy(duration: 0.2)) { selectTab(tab, side: side, in: runtime) }
    }

    /// Asks to close a sub-tab. The primary (first) tab of each pane is never closable.
    func requestCloseTab(_ tab: PaneTab, side: PaneSide) {
        guard let context = selected, tab.id != context.tabs(side).first?.id else { return }
        closingTab = ClosingTab(tab: tab, side: side)
    }

    /// ⌘W: asks to close the sub-tab shown in the focused pane; no-op on a primary tab.
    func requestCloseCurrentTab() {
        guard let context = selected, let runtime = runtimes[context.id] else { return }
        let side = focusedSide()
        guard let tab = context.tabs(side).first(where: { $0.id == runtime.selectedTab(side) }) else { return }
        requestCloseTab(tab, side: side)
    }

    /// Closes a sub-tab and kills its tmux session, then focuses that pane's primary tab.
    func closeTab(_ tab: PaneTab, side: PaneSide) {
        closingTab = nil
        guard let context = selected, tab.id != context.tabs(side).first?.id else { return }
        update(context.id) { $0.setTabs(side, $0.tabs(side).filter { $0.id != tab.id }) }
        Task { await PaneTmux.kill(context, side, tabs: [tab]) }
        focusPane(side)
    }

    func renameTab(_ tab: PaneTab, side: PaneSide, to name: String) {
        guard let context = selected else { return }
        update(context.id) { ctx in
            var tabs = ctx.tabs(side)
            if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[i].name = name }
            ctx.setTabs(side, tabs)
        }
    }
}

/// macOS notifications; only available when running as a bundled .app.
enum Notifier {
    private static var authorized = false
    private static var requested = false

    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if authorized { send(); return }
        guard !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
            if granted { send() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onBecomeActive: (() -> Void)?

    func applicationDidBecomeActive(_ notification: Notification) {
        onBecomeActive?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Transparent window so the frosted background shows; panes are opaque cards on top.
        for window in NSApp.windows {
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HeliosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Helios", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.onBecomeActive = { [weak model] in model?.appDidBecomeActive() } }
                .frame(minWidth: 900, minHeight: 500)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // ⌘W closes the focused pane's sub-tab instead of the window (which would quit Helios).
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { model.requestCloseCurrentTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Context") { model.beginNew() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Edit Context…") { model.beginEditSelected() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Restart Context Terminals") { model.restartSelected() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                // Tab shortcuts act on whichever pane has keyboard focus.
                Button("New Tab in Pane") { model.addTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Next Tab in Pane") { model.selectAdjacentTab(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Previous Tab in Pane") { model.selectAdjacentTab(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Command Palette…") { model.isPaletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Focus Left Pane") { model.focusPane(.left) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Focus Right Pane") { model.focusPane(.right) }
                    .keyboardShortcut("]", modifiers: .command)
            }
            CommandMenu("Panels") {
                Button("Toggle Drawer") { model.toggleDrawer() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                ForEach(Array(DrawerTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.rawValue) { model.toggleDrawer(tab) }
                }
            }
            CommandMenu("Contexts") {
                Button("Next Context") { model.selectAdjacent(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Context") { model.selectAdjacent(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button("Context \(index + 1)") { model.select(index: index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}
