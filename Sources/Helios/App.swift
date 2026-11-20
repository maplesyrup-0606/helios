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
    /// SSH sub-tab awaiting close confirmation (closing kills its remote tmux session).
    @Published var closingRemoteTab: RemoteTab?
    /// Context being edited in the sheet; `isNewContext` distinguishes add from edit.
    @Published var editing: WorkContext?
    @Published var isNewContext = false
    /// Open drawer tab under the terminals; nil when the drawer is closed.
    @Published var drawerTab: DrawerTab?
    private var runtimes: [UUID: ContextRuntime] = [:]

    init() {
        selectedID = store.contexts.first?.id
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

    func commit(_ context: WorkContext) {
        objectWillChange.send()
        if let index = store.contexts.firstIndex(where: { $0.id == context.id }) {
            let old = store.contexts[index]
            store.contexts[index] = context
            // Restart terminals only when something they were launched with changed.
            // The startup command only applies to newly created sessions, so editing it never
            // interrupts a running one. A new local dir needs a fresh local tmux session.
            if old.localDir != context.localDir || old.host != context.host || old.remoteDir != context.remoteDir {
                if old.localDir != context.localDir {
                    runtimes[context.id]?.shutdown()
                    LocalTmux.kill(old)
                }
                restart(context.id)
            } else {
                runtimes[context.id]?.update(context)
            }
        } else {
            store.contexts.append(context)
        }
        selectedID = context.id
        editing = nil
    }

    func delete(_ id: UUID) {
        objectWillChange.send()
        runtimes.removeValue(forKey: id)?.shutdown()
        if let context = store.contexts.first(where: { $0.id == id }) { LocalTmux.kill(context) }
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

    /// Returns keyboard focus to the selected context's local terminal.
    func focusSelectedTerminal() {
        focusPane(remote: false)
    }

    /// Moves keyboard focus to the local (left) or SSH (right) terminal of the selected context.
    func focusPane(remote: Bool) {
        guard let selected, let runtime = runtimes[selected.id] else { return }
        let target: NSView
        if remote {
            guard let id = runtime.selectedRemoteTab ?? selected.remoteTabs.first?.id,
                  let session = runtime.remoteSessions[id] else { return }
            target = session.terminal
        } else {
            target = runtime.local.terminal
        }
        FocusTracker.shared.request(target)
    }

    func toggleDrawer(_ tab: DrawerTab? = nil) {
        let target = tab ?? drawerTab ?? (selected?.hasHost == true ? .jobs : .git)
        withAnimation(.snappy(duration: 0.28)) { drawerTab = drawerTab == target ? nil : target }
    }

    // MARK: SSH sub-tabs

    func addRemoteTab() {
        guard let context = selected, context.hasHost else { return }
        let tab = RemoteTab(name: "shell \(context.remoteTabs.count + 1)")
        update(context.id) { $0.remoteTabs.append(tab) }
        if let runtime = runtimes[context.id], let session = runtime.session(for: tab) {
            runtime.selectedRemoteTab = tab.id
            // Type into the new tab right away, without clicking it.
            FocusTracker.shared.request(session.terminal)
        }
    }

    /// Asks to close a sub-tab. The primary (first) tab is never closable.
    func requestCloseRemoteTab(_ tab: RemoteTab) {
        guard let context = selected, tab.id != context.remoteTabs.first?.id else { return }
        closingRemoteTab = tab
    }

    /// ⌘W: asks to close the SSH sub-tab currently shown; no-op on the primary tab.
    func requestCloseCurrentRemoteTab() {
        guard let context = selected, let runtime = runtimes[context.id],
              let id = runtime.selectedRemoteTab,
              let tab = context.remoteTabs.first(where: { $0.id == id }) else { return }
        requestCloseRemoteTab(tab)
    }

    /// Closes a sub-tab and kills its remote tmux session. The primary tab can't be closed.
    func closeRemoteTab(_ tab: RemoteTab) {
        closingRemoteTab = nil
        guard let context = selected, tab.id != context.remoteTabs.first?.id else { return }
        let session = context.tmuxSession(for: tab)
        let host = context.host
        update(context.id) { $0.remoteTabs.removeAll { $0.id == tab.id } }
        Task.detached { _ = await Shell.remote(host, "tmux kill-session -t \(session) 2>/dev/null", timeout: 15) }
        // Land back in the primary SSH tab, ready to type.
        focusPane(remote: true)
    }

    /// ⇧⌘← / ⇧⌘→: previous/next SSH sub-tab (wraps), focusing its shell.
    func selectAdjacentRemoteTab(_ offset: Int) {
        guard let context = selected, context.hasHost, let runtime = runtimes[context.id] else { return }
        let tabs = context.remoteTabs
        guard tabs.count > 1 else { focusPane(remote: true); return }
        let current = tabs.firstIndex { $0.id == runtime.selectedRemoteTab } ?? 0
        let next = tabs[(current + offset + tabs.count) % tabs.count]
        runtime.selectedRemoteTab = next.id
        if let session = runtime.session(for: next) { FocusTracker.shared.request(session.terminal) }
    }

    func renameRemoteTab(_ tab: RemoteTab, to name: String) {
        guard let context = selected else { return }
        update(context.id) { ctx in
            if let i = ctx.remoteTabs.firstIndex(where: { $0.id == tab.id }) { ctx.remoteTabs[i].name = name }
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
            // ⌘W closes the current SSH sub-tab instead of the window (which would quit Helios).
            CommandGroup(replacing: .saveItem) {
                Button("Close SSH Tab") { model.requestCloseCurrentRemoteTab() }
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
                Button("New SSH Tab") { model.addRemoteTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Next SSH Tab") { model.selectAdjacentRemoteTab(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Previous SSH Tab") { model.selectAdjacentRemoteTab(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Command Palette…") { model.isPaletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Focus Local Pane") { model.focusPane(remote: false) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Focus SSH Pane") { model.focusPane(remote: true) }
                    .keyboardShortcut("]", modifiers: .command)
            }
            CommandMenu("Panels") {
                Button("Toggle Drawer") { model.toggleDrawer() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                ForEach(Array(DrawerTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.rawValue) { model.toggleDrawer(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
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
