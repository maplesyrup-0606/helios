import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let theme = Theme.current

// MARK: - Resizable split

/// Two views separated by a draggable gap. `ratio` is the first view's share; it is reported
/// through `onCommit` when a drag ends so callers can persist it. When `showsSecond` is false the
/// first view fills the space, but the hierarchy stays the same so hosted terminals aren't rebuilt.
struct ResizableSplit<First: View, Second: View>: View {
    let axis: Axis
    let ratio: Double
    var range: ClosedRange<Double> = 0.2...0.8
    var showsSecond = true
    var gap: CGFloat = 8
    let onCommit: (Double) -> Void
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    @State private var liveRatio: Double?
    @State private var isHandleHovered = false

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let usable = max(0, total - gap)
            let firstSize = showsSecond ? usable * (liveRatio ?? ratio) : total
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first.frame(width: axis == .horizontal ? firstSize : nil, height: axis == .vertical ? firstSize : nil)
                if showsSecond {
                    handle(total: total)
                    second
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: axis == .horizontal ? .trailing : .bottom).combined(with: .opacity))
                }
            }
        }
        .coordinateSpace(name: "split")
    }

    private func handle(total: CGFloat) -> some View {
        let active = isHandleHovered || liveRatio != nil
        return ZStack {
            Color.clear
            Capsule()
                .fill(active ? theme.accent.opacity(0.8) : theme.fillStrong)
                .frame(width: axis == .horizontal ? 3 : 36, height: axis == .vertical ? 3 : 36)
                .opacity(active ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(width: axis == .horizontal ? gap : nil, height: axis == .vertical ? gap : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            isHandleHovered = inside
            let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
            inside ? cursor.push() : NSCursor.pop()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                .onChanged { value in
                    let position = axis == .horizontal ? value.location.x : value.location.y
                    liveRatio = min(range.upperBound, max(range.lowerBound, position / max(total, 1)))
                }
                .onEnded { _ in
                    if let liveRatio { onCommit(liveRatio) }
                    liveRatio = nil
                }
        )
    }
}

/// A floating rounded panel: the building block for terminals and the drawer.
struct Card<Header: View, Content: View>: View {
    var isFocused = false
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 32)
                .frame(maxWidth: .infinity)
            content
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.canvas))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? theme.accent.opacity(0.55) : theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .shadow(color: isFocused ? theme.accent.opacity(0.12) : .clear, radius: 18)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

// MARK: - Drawer

struct Drawer: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var pill
    let context: WorkContext
    let runtime: ContextRuntime
    let tab: DrawerTab
    /// Sends text to the focused SSH sub-tab (used by Files → "cd here").
    let sendToSSH: (String) -> Void

    private var tabs: [DrawerTab] {
        DrawerTab.allCases.filter { !$0.needsHost || context.hasHost }
    }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(tabs) { item in
                        DrawerTabButton(title: item.rawValue, isSelected: item == tab, namespace: pill) {
                            withAnimation(.snappy(duration: 0.22)) { model.drawerTab = item }
                        }
                    }
                }
                .padding(3)
                .background(Capsule().fill(theme.fill))
                Spacer()
                IconButton(systemName: "chevron.down", help: "Close drawer (⌘I)") {
                    withAnimation(.snappy(duration: 0.25)) { model.drawerTab = nil }
                }
            }
            .padding(.horizontal, 8)
        } content: {
            Rectangle().fill(theme.hairline).frame(height: 1)
            Group {
                switch tab {
                case .jobs:
                    if let jobs = runtime.jobs { JobsPanel(jobs: jobs) } else { Placeholder(text: "No SSH host") }
                case .git:
                    GitPanel(git: runtime.git)
                case .notes:
                    NotesPanel(contextID: context.id, text: context.notes)
                case .files:
                    if let files = runtime.files { FilesPanel(files: files, sendToSSH: sendToSSH) } else { Placeholder(text: "No SSH host") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DrawerTabButton: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.text : (isHovered ? theme.textMuted : theme.textFaint))
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(theme.fillStrong)
                            .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
                            .matchedGeometryEffect(id: "pill", in: namespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var isActive = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? theme.accent : (isHovered ? theme.text : theme.textMuted))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isActive ? theme.fillStrong : (isHovered ? theme.fill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct TextAction: View {
    let title: String
    var color: Color = theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

private struct Placeholder: View {
    let text: String
    var detail: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(text).font(.system(size: 12)).foregroundStyle(theme.textMuted)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(theme.textFaint) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(theme.textFaint)
    }
}

// MARK: - Jobs

private struct JobsPanel: View {
    @ObservedObject var jobs: JobsMonitor
    @State private var pendingCancel: JobsMonitor.Job?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                Rectangle().fill(theme.hairline).frame(height: 1)
                content
            }
            if !jobs.detailTitle.isEmpty {
                Rectangle().fill(theme.hairline).frame(width: 1)
                detail.frame(width: 380)
            }
        }
        .confirmationDialog("Cancel job \(pendingCancel?.id ?? "")?", isPresented: Binding(
            get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }
        ), presenting: pendingCancel) { job in
            Button("scancel \(job.id) (\(job.name))", role: .destructive) { Task { await jobs.cancel(job) } }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SectionLabel(text: "squeue · \(jobs.host)")
            if let updated = jobs.lastUpdated {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("updated \(updated.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textFaint)
                }
            }
            Spacer()
            TextAction(title: "GPU (login)") { Task { await jobs.showGPU() } }
            TextAction(title: "quota") { Task { await jobs.showQuota() } }
            IconButton(systemName: "arrow.clockwise", help: "Refresh") { Task { await jobs.refresh() } }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder private var content: some View {
        switch jobs.status {
        case .loading:
            Placeholder(text: "Loading…")
        case .notConnected:
            Placeholder(text: "Not connected", detail: "Authenticate in the SSH pane; jobs load over that connection.")
        case .unavailable:
            Placeholder(text: "No SLURM on \(jobs.host)")
        case let .error(message):
            Placeholder(text: "squeue failed", detail: message)
        case .ok where jobs.jobs.isEmpty:
            Placeholder(text: "No jobs in the queue")
        case .ok:
            ScrollView {
                LazyVStack(spacing: 0) {
                    JobRow.header
                    ForEach(jobs.jobs) { job in
                        JobRow(job: job,
                               progress: jobs.progress[job.id],
                               onGPU: { Task { await jobs.showGPU(for: job) } },
                               onDetails: { Task { await jobs.showJobDetails(job) } },
                               onCancel: { pendingCancel = job })
                    }
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(jobs.detailTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer()
                IconButton(systemName: "xmark", help: "Close") { jobs.clearDetail() }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(theme.hairline).frame(height: 1)
            if jobs.isRunningDetail {
                Placeholder(text: "Running…")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(jobs.detailOutput.isEmpty ? "(no output)" : jobs.detailOutput)
                        .font(theme.mono(11))
                        .foregroundStyle(theme.textMuted)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct JobRow: View {
    let job: JobsMonitor.Job
    let progress: JobsMonitor.Progress?
    let onGPU: () -> Void
    let onDetails: () -> Void
    let onCancel: () -> Void
    @State private var isHovered = false

    static var header: some View {
        HStack(spacing: 10) {
            Text("ST").frame(width: 28, alignment: .leading)
            Text("JOB").frame(width: 80, alignment: .leading)
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("TIME / LIMIT").frame(width: 140, alignment: .leading)
            Text("PARTITION").frame(width: 90, alignment: .leading)
            Text("NODES / REASON").frame(width: 150, alignment: .leading)
            Color.clear.frame(width: 120)
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(theme.textFaint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var stateColor: Color {
        job.isRunning ? theme.ok : (job.isPending ? theme.warn : theme.textMuted)
    }

    private var stateCode: String {
        switch job.state {
        case "RUNNING": "R"
        case "PENDING": "PD"
        case "COMPLETING": "CG"
        case "CONFIGURING": "CF"
        default: String(job.state.prefix(2))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            mainLine
            if let progress {
                ProgressLine(progress: progress)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? theme.fill : .clear).padding(.horizontal, 4))
        .onHover { isHovered = $0 }
    }

    private var mainLine: some View {
        HStack(spacing: 10) {
            Text(stateCode)
                .font(theme.mono(10, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 28, alignment: .leading)
            Text(job.id).frame(width: 80, alignment: .leading)
            Text(job.name).foregroundStyle(theme.text).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(job.elapsed) / \(job.limit)").frame(width: 140, alignment: .leading)
            Text(job.partition).frame(width: 90, alignment: .leading)
                .help(job.partition)
            // squeue already wraps pending reasons in parentheses.
            Text(job.reason)
                .foregroundStyle(job.isRunning ? theme.textMuted : theme.textFaint)
                .frame(width: 150, alignment: .leading)
                .help(job.reason)
            HStack(spacing: 10) {
                if isHovered {
                    if job.isRunning { TextAction(title: "gpu", action: onGPU) }
                    TextAction(title: "info", action: onDetails)
                    TextAction(title: "cancel", color: theme.error, action: onCancel)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .font(theme.mono(11))
        .foregroundStyle(theme.textMuted)
        .lineLimit(1)
    }
}

/// tqdm progress for a running job: bar, percent, counts, ETA, rate, postfix.
private struct ProgressLine: View {
    let progress: JobsMonitor.Progress

    var body: some View {
        HStack(spacing: 10) {
            if !progress.label.isEmpty {
                Text(progress.label).foregroundStyle(theme.text)
            }
            ProgressBar(fraction: progress.fraction)
                .frame(width: 140, height: 5)
            Text("\(Int((progress.fraction * 100).rounded()))%")
                .foregroundStyle(theme.accent)
                .frame(width: 34, alignment: .trailing)
            Text(progress.counts)
            if !progress.remaining.isEmpty && progress.remaining != "?" {
                Text("eta \(progress.remaining)").foregroundStyle(theme.text)
            }
            if !progress.rate.isEmpty { Text(progress.rate).foregroundStyle(theme.textFaint) }
            if !progress.postfix.isEmpty {
                Text(progress.postfix).foregroundStyle(theme.textFaint).truncationMode(.tail)
            }
        }
        .font(theme.mono(10.5))
        .foregroundStyle(theme.textMuted)
        .lineLimit(1)
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.fillStrong)
                Capsule()
                    .fill(LinearGradient(colors: [theme.accent.opacity(0.7), theme.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * fraction))
                    .shadow(color: theme.accent.opacity(0.5), radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: - Git

private struct GitPanel: View {
    @ObservedObject var git: GitMonitor

    var body: some View {
        if !git.isRepo && git.remote == nil {
            Placeholder(text: "Not a git repository")
        } else {
            VStack(spacing: 0) {
                if let remote = git.remote {
                    remoteRow(remote)
                    Rectangle().fill(theme.hairline).frame(height: 1)
                }
                if git.isRepo {
                    columns
                } else {
                    Placeholder(text: "Local folder is not a git repository")
                }
            }
        }
    }

    /// The cluster checkout's status, which can differ from the local repo shown below it.
    private func remoteRow(_ remote: GitMonitor.RemoteStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 10)).foregroundStyle(theme.textFaint)
            Text(git.host ?? "remote").font(.system(size: 11)).foregroundStyle(theme.textFaint)
            Text(remote.branch).font(theme.mono(11, weight: .semibold)).foregroundStyle(theme.accent)
            Text(remote.changeCount == 0 ? "clean" : "\(remote.changeCount) changed")
                .font(.system(size: 11)).foregroundStyle(remote.changeCount == 0 ? theme.textFaint : theme.warn)
            if !remote.tracking.isEmpty {
                Text(remote.tracking).font(.system(size: 11)).foregroundStyle(theme.textFaint)
            }
            if git.isRepo, remote.branch != git.branch {
                Text("local is on \(git.branch)").font(.system(size: 11)).foregroundStyle(theme.warn)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            column(title: "Changes · \(git.changes.count)") {
                if git.changes.isEmpty {
                    Text("Working tree clean").font(.system(size: 11)).foregroundStyle(theme.textFaint)
                }
                ForEach(git.changes) { change in
                    HStack(spacing: 10) {
                        Text(change.status)
                            .font(theme.mono(11, weight: .semibold))
                            .foregroundStyle(color(for: change.status))
                            .frame(width: 22, alignment: .leading)
                        Text(change.path).font(theme.mono(11)).foregroundStyle(theme.textMuted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Rectangle().fill(theme.hairline).frame(width: 1)
            column(title: "Recent commits") {
                ForEach(git.commits) { commit in
                    HStack(spacing: 10) {
                        Text(commit.id).font(theme.mono(11)).foregroundStyle(theme.accent)
                        Text(commit.subject).font(.system(size: 12)).foregroundStyle(theme.textMuted).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(commit.age).font(.system(size: 10)).foregroundStyle(theme.textFaint)
                    }
                }
            }
        }
    }

    private func column<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: title).padding(.bottom, 4)
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func color(for status: String) -> Color {
        switch status.first {
        case "M": theme.warn
        case "A": theme.ok
        case "D": theme.error
        case "?": theme.textFaint
        default: theme.accent
        }
    }
}

// MARK: - Notes

private struct NotesPanel: View {
    @EnvironmentObject private var model: AppModel
    let contextID: UUID
    @State var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(theme.mono(12))
            .foregroundStyle(theme.text)
            .scrollContentBackground(.hidden)
            .padding(10)
            .onChange(of: text) { _, newValue in
                model.update(contextID) { $0.notes = newValue }
            }
    }
}

// MARK: - Files

private struct FilesPanel: View {
    @ObservedObject var files: FileBrowser
    let sendToSSH: (String) -> Void
    @State private var selection = Set<String>()
    @State private var isDropTarget = false

    private var selectedEntries: [FileBrowser.Entry] {
        files.entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(systemName: "chevron.up", help: "Parent directory") { Task { await files.goUp() } }
                Text(files.path.isEmpty ? "…" : files.path)
                    .font(theme.mono(11))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                TextAction(title: "cd here") { sendToSSH("cd \(remoteShellPath(files.path))\r") }
                TextAction(title: "upload…", action: chooseUpload)
                TextAction(title: selection.isEmpty ? "download" : "download \(selection.count)") {
                    Task { await files.download(selectedEntries) }
                }
                .disabled(selection.isEmpty)
                .opacity(selection.isEmpty ? 0.4 : 1)
                IconButton(systemName: "arrow.clockwise", help: "Refresh") { Task { await files.load() } }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Rectangle().fill(theme.hairline).frame(height: 1)

            Group {
                if let error = files.error {
                    Placeholder(text: "Couldn't list directory", detail: error)
                } else if files.isLoading && files.entries.isEmpty {
                    Placeholder(text: "Loading…")
                } else {
                    List(selection: $selection) {
                        ForEach(files.entries) { entry in
                            FileRow(entry: entry)
                                .tag(entry.id)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button("Download to local dir") {
                            Task { await files.download(files.entries.filter { ids.contains($0.id) }) }
                        }
                        Button("Copy path") {
                            let paths = files.entries.filter { ids.contains($0.id) }.map(files.fullPath)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                        }
                    } primaryAction: { ids in
                        if ids.count == 1, let entry = files.entries.first(where: { ids.contains($0.id) }), entry.isDirectory {
                            selection = []
                            Task { await files.open(entry) }
                        }
                    }
                }
            }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(6)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                Task { await files.upload(await fileURLs(from: providers)) }
                return true
            }

            if let status = files.transferStatus {
                Rectangle().fill(theme.hairline).frame(height: 1)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(status.hasPrefix("Transfer failed") ? theme.error : theme.textMuted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .task { await files.loadIfNeeded() }
        .onChange(of: files.path) { _, _ in selection = [] }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await files.upload(urls) }
        }
    }
}

@MainActor
private func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers {
        let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
        if let url = item as? URL {
            urls.append(url)
        } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            urls.append(url)
        }
    }
    return urls
}

private struct FileRow: View {
    let entry: FileBrowser.Entry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(entry.isDirectory ? theme.accent : theme.textFaint)
                .frame(width: 16)
            Text(entry.name)
                .font(theme.mono(11.5))
                .foregroundStyle(entry.isDirectory ? theme.text : theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.textFaint)
                    .frame(width: 70, alignment: .trailing)
            }
            Text(entry.modified.formatted(.relative(presentation: .numeric)))
                .font(.system(size: 10))
                .foregroundStyle(theme.textFaint)
                .frame(width: 90, alignment: .trailing)
        }
    }
}
