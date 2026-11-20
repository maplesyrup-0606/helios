import AppKit
import SwiftUI

enum DrawerTab: String, CaseIterable, Identifiable {
    case jobs = "Jobs", git = "Git", notes = "Notes", files = "Files"
    var id: String { rawValue }
    var needsHost: Bool { self == .jobs || self == .files }
}

/// App-wide state: saved contexts, the selected tab, and the live terminals per context.
@MainActor
final class AppModel: ObservableObject {
    let store = ContextStore()
    @Published var selectedID: UUID?
    /// Context being edited in the sheet; `isNewContext` distinguishes add from edit.
    @Published var editing: WorkContext?
    @Published var isNewContext = false
    /// Open drawer tab under the terminals; nil when the drawer is closed.
    @Published var drawerTab: DrawerTab?
    private var runtimes: [UUID: ContextRuntime] = [:]

    init() {
        selectedID = store.contexts.first?.id
    }

    var contexts: [WorkContext] { store.contexts }
    var selected: WorkContext? { store.contexts.first { $0.id == selectedID } }

    /// Terminals start lazily the first time a tab is shown.
    func runtime(for context: WorkContext) -> ContextRuntime {
        if let existing = runtimes[context.id] { return existing }
        let runtime = ContextRuntime(context: context)
        runtimes[context.id] = runtime
        return runtime
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
            if old.localDir != context.localDir || old.startupCommand != context.startupCommand
                || old.host != context.host || old.remoteDir != context.remoteDir {
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
        store.contexts.removeAll { $0.id == id }
        if selectedID == id { selectedID = store.contexts.first?.id }
        editing = nil
    }

    func restart(_ id: UUID) {
        objectWillChange.send()
        runtimes.removeValue(forKey: id)?.shutdown()
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

    func toggleDrawer(_ tab: DrawerTab? = nil) {
        let target = tab ?? drawerTab ?? (selected?.hasHost == true ? .jobs : .git)
        withAnimation(.snappy(duration: 0.28)) { drawerTab = drawerTab == target ? nil : target }
    }

    // MARK: SSH sub-tabs

    func addRemoteTab() {
        guard let context = selected, context.hasHost else { return }
        let tab = RemoteTab(name: "shell \(context.remoteTabs.count + 1)")
        update(context.id) { $0.remoteTabs.append(tab) }
        if let runtime = runtimes[context.id] {
            _ = runtime.session(for: tab)
            runtime.selectedRemoteTab = tab.id
        }
    }

    /// Closes a sub-tab and kills its remote tmux session. The primary tab can't be closed.
    func closeRemoteTab(_ tab: RemoteTab) {
        guard let context = selected, tab.id != context.remoteTabs.first?.id else { return }
        let session = context.tmuxSession(for: tab)
        let host = context.host
        update(context.id) { $0.remoteTabs.removeAll { $0.id == tab.id } }
        Task.detached { _ = await Shell.remote(host, "tmux kill-session -t \(session) 2>/dev/null", timeout: 15) }
    }

    func renameRemoteTab(_ tab: RemoteTab, to name: String) {
        guard let context = selected else { return }
        update(context.id) { ctx in
            if let i = ctx.remoteTabs.firstIndex(where: { $0.id == tab.id }) { ctx.remoteTabs[i].name = name }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
                .frame(minWidth: 900, minHeight: 500)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Context") { model.beginNew() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Edit Context…") { model.beginEditSelected() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Restart Context Terminals") { model.restartSelected() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("New SSH Tab") { model.addRemoteTab() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
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
