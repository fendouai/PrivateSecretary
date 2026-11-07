import SwiftUI
import AppKit
import AVFoundation
import SecretaryKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case timeline = "Timeline"
    case todos = "Todos"
    case contacts = "Contacts"
    case messages = "Messages"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .timeline: return "clock.arrow.circlepath"
        case .todos: return "checklist"
        case .contacts: return "person.2"
        case .messages: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("Private Secretary")
            Text(menuSummary)
            Divider()
            Button("Open Private Secretary") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Open Dashboard") { model.openDashboard() }
            Button("Open Data Folder") { model.openDataFolder() }
            Divider()
            if model.isServiceRunning {
                Button("Restart Capture Service") { model.restartService() }
            } else {
                Button("Start Capture Service") { model.startService() }
                    .disabled(model.serviceBusy)
            }
            Divider()
            Button("Quit Private Secretary") { NSApp.terminate(nil) }
        }
    }

    private var menuSummary: String {
        guard let counts = model.status?.counts else { return "Loading…" }
        return "\(counts.episodes) episodes · \(counts.openTodos) open todos · \(counts.messages) messages"
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .listStyle(.sidebar)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { model.refresh() }
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .padding(8)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview: OverviewView(model: model)
        case .timeline: TimelineView(model: model)
        case .todos: TodosView(model: model)
        case .contacts: ContactsView(model: model)
        case .messages: MessagesView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Good to see you", subtitle: "A calm, read-only view of what your Mac has organized.")

                HStack(spacing: 12) {
                    StatCard(title: "Episodes", value: "\(model.status?.counts.episodes ?? 0)", icon: "rectangle.stack")
                    StatCard(title: "Open Todos", value: "\(model.status?.counts.openTodos ?? 0)", icon: "checklist")
                    StatCard(title: "Contacts", value: "\(model.status?.counts.contacts ?? 0)", icon: "person.2")
                    StatCard(title: "Messages", value: "\(model.status?.counts.messages ?? 0)", icon: "bubble.left.and.bubble.right")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle()
                                .fill(model.isServiceRunning ? .green : .orange)
                                .frame(width: 9, height: 9)
                            Text("Capture service: \(model.serviceStateLabel)").font(.headline)
                            Spacer()
                            Text(model.status?.capture.detail ?? "No status yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        HStack {
                            Button(model.isServiceRunning ? "Restart Service" : "Start Service") {
                                if model.isServiceRunning {
                                    model.restartService()
                                } else {
                                    model.startService()
                                }
                            }
                            .disabled(model.serviceBusy)
                            Button("Stop Service") { model.stopService() }
                                .disabled(model.serviceBusy || !model.isServiceRunning)
                            Spacer()
                            Button("Refresh") { model.refresh() }
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Service", systemImage: "bolt.horizontal.circle")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        PermissionRow(
                            title: "Screen Recording",
                            granted: model.screenPermission,
                            action: "Grant",
                            detail: "Required to read changed screen regions."
                        ) {
                            model.requestScreenRecording()
                        }
                        Divider()
                        PermissionRow(
                            title: "Microphone",
                            granted: model.microphonePermission == .authorized,
                            action: "Grant",
                            detail: "Optional. System audio is the default."
                        ) {
                            model.requestMicrophone()
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Permissions", systemImage: "lock.shield")
                }

                GroupBox {
                    HStack {
                        Button("Generate Today's Digest") { model.generateDigest() }
                        Button("Copy Daily Brief") { model.copyDailyBrief() }
                        Button("Open HTML Dashboard") { model.openDashboard() }
                        Button("Open Data Folder") { model.openDataFolder() }
                        Spacer()
                    }
                    .padding(4)
                } label: {
                    Label("Brief & data", systemImage: "doc.text.magnifyingglass")
                }

                if let brief = model.brief, !brief.timeline.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(brief.timeline.prefix(5)) { entry in
                                TimelineRow(entry: entry) { model.openDrillDown(entry.memoryID) }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Recent timeline", systemImage: "clock")
                    }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: Binding(
            get: { model.selectedMemory != nil },
            set: { if !$0 { model.selectedMemory = nil } }
        )) {
            if let result = model.selectedMemory {
                MemoryDetailView(result: result) { model.selectedMemory = nil }
            }
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: String
    let detail: String
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(action) { request() } }
        }
    }
}

struct TimelineView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Timeline", subtitle: "Structured experiences and the facts consolidated from them.")
            HStack {
                DatePicker("Day", selection: $model.selectedDate, displayedComponents: .date)
                    .onChange(of: model.selectedDate) { _, _ in model.refresh() }
                Spacer()
                Button("Refresh") { model.refresh() }
            }
            if let entries = model.brief?.timeline, !entries.isEmpty {
                List(entries) { entry in
                    TimelineRow(entry: entry) { model.openDrillDown(entry.memoryID) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                EmptyState(icon: "clock", title: "Nothing on this day", detail: "Capture is off or no memory was stored.")
            }
        }
        .padding(24)
        .sheet(isPresented: Binding(
            get: { model.selectedMemory != nil },
            set: { if !$0 { model.selectedMemory = nil } }
        )) {
            if let result = model.selectedMemory {
                MemoryDetailView(result: result) { model.selectedMemory = nil }
            }
        }
    }
}

private struct TimelineRow: View {
    let entry: TimelineEntry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Text(DateCoding.timeOnly(entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                Text(entry.kind == .episode ? "L2" : "L3")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Text(entry.memoryID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

struct TodosView: View {
    @ObservedObject var model: AppModel
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Todos", subtitle: "Captured intentions for you. Nothing here is executed automatically.")
            HStack {
                TextField("Add a todo…", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Picker("Show", selection: $model.todoFilter) {
                    ForEach(TodoFilter.allCases) { filter in Text(filter.label).tag(filter) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .onChange(of: model.todoFilter) { _, _ in model.refresh() }
            }
            if model.todos.isEmpty {
                EmptyState(icon: "checklist", title: "No todos", detail: "Say “帮我记一下…” or add one here.")
            } else {
                List(model.todos) { todo in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            model.setTodo(todo, done: todo.status != .done)
                        } label: {
                            Image(systemName: todo.status == .done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(todo.status == .done ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(todo.title)
                                .strikethrough(todo.status == .done)
                                .foregroundStyle(todo.status == .done ? .secondary : .primary)
                            if !todo.detail.isEmpty {
                                Text(todo.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack(spacing: 8) {
                                Text(todo.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                if let due = todo.dueAt {
                                    Text("due \(DateCoding.human(due))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Mark Open") { model.setTodo(todo, done: false) }
                            Button("Mark Done") { model.setTodo(todo, done: true) }
                            Button("Dismiss") { model.dismissTodo(todo) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 26)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(24)
    }

    private func add() {
        let title = newTitle
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.addTodo(title)
        newTitle = ""
    }
}

struct ContactsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Contacts", subtitle: "People aggregated across your local channel adapters.")
            if model.contacts.isEmpty {
                EmptyState(icon: "person.2", title: "No contacts", detail: "Import messages to build your contact list.")
            } else {
                List(model.contacts) { contact in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(contact.displayName).font(.headline)
                            if let organization = contact.organization, !organization.isEmpty {
                                Text(organization).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(contact.messageCount) messages").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(contact.channels.map { "\($0.channel): \($0.handle)" }.joined(separator: "   "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let snippet = contact.lastMessageSnippet {
                            Text(snippet).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(24)
    }
}

struct MessagesView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Messages", subtitle: "Archived across channels. Private Secretary never sends or replies.")
            HStack {
                TextField("Search messages…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.messageQuery = query; model.refresh() }
                Button("Search") { model.messageQuery = query; model.refresh() }
                Toggle("Unread only", isOn: $model.unreadOnly)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.unreadOnly) { _, _ in model.refresh() }
            }
            if model.messages.isEmpty {
                EmptyState(icon: "bubble.left", title: "No messages", detail: "Use message import or connect a local channel adapter.")
            } else {
                List(model.messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(message.contactName).font(.headline)
                            Text(message.channel).font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(message.direction == .inbound ? "in" : "out").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(DateCoding.human(message.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if !message.isRead {
                                Circle().fill(.blue).frame(width: 7, height: 7)
                                Button("Read") { model.markRead(message) }.buttonStyle(.link)
                            }
                        }
                        Text(message.text).font(.callout)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(24)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Settings", subtitle: "Local paths and service status.")
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Memory home", value: model.paths.home.path)
                        LabeledContent("Database", value: model.paths.databaseFile.path)
                        LabeledContent("Version", value: model.status?.version ?? PrivateSecretaryVersion.current)
                        LabeledContent("Intent model", value: model.status?.intentModel ?? "rules")
                        LabeledContent("Extraction model", value: model.status?.extractionModel ?? "rules")
                    }
                    .padding(4)
                } label: {
                    Label("Local data", systemImage: "internaldrive")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Capture is optional. Grant Screen Recording, then start the service.")
                        Toggle("Microphone capture", isOn: Binding(
                            get: { model.microphoneEnabled },
                            set: { model.setMicrophoneEnabled($0) }
                        ))
                        .toggleStyle(.checkbox)
                        Text("System audio is captured by default. Microphone uses the app's permission and takes effect after restarting the service.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Screen Recording Settings") { model.openScreenRecordingSettings() }
                            Button("Open Data Folder") { model.openDataFolder() }
                            Spacer()
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Permissions", systemImage: "lock")
                }
            }
            .padding(24)
        }
    }
}

struct MemoryDetailView: View {
    let result: DrillDownResult
    let close: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(result.fact == nil ? "Episode" : "Fact").font(.title2.weight(.semibold))
                Text(result.memoryID).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Copy as Context") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ContextExporter.markdown(result), forType: .string)
                }
                Button("Close") { close(); dismiss() }
            }
            Text("⚠️ \(result.warning)").font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                if let fact = result.fact {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fact.statement).font(.body)
                        LabeledContent("Status", value: fact.status.rawValue)
                        LabeledContent("Kind", value: fact.kind.rawValue)
                        LabeledContent("Sources", value: fact.sourceEpisodeIDs.joined(separator: ", "))
                        LabeledContent("Confidence", value: String(format: "%.2f", fact.confidence))
                    }
                } else if let content = result.content {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(content.displayTitle).font(.headline)
                        Text(DateCoding.human(content.startedAt)).font(.caption).foregroundStyle(.secondary)
                        Text(content.transcript.isEmpty ? "(no transcript)" : content.transcript)
                            .textSelection(.enabled)
                        if !content.ocrText.isEmpty {
                            Divider()
                            Text("OCR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(content.ocrText).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 420)
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
