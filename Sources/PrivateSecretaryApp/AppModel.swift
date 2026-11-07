import Foundation
import Combine
import AppKit
import CoreGraphics
import AVFoundation
import SecretaryKit

enum TodoFilter: String, CaseIterable, Identifiable {
    case open
    case done
    case all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .open: return "Open"
        case .done: return "Done"
        case .all: return "All"
        }
    }
    var status: TodoStatus? {
        switch self {
        case .open: return .open
        case .done: return .done
        case .all: return nil
        }
    }
}

final class AppModel: ObservableObject {
    @Published var status: ServiceStatus?
    @Published var brief: DailyBrief?
    @Published var todos: [TodoItem] = []
    @Published var contacts: [Contact] = []
    @Published var messages: [ContactMessage] = []
    @Published var selectedDate = Date()
    @Published var todoFilter: TodoFilter = .open
    @Published var messageQuery = ""
    @Published var unreadOnly = false
    @Published var isRefreshing = false
    @Published var screenPermission = false
    @Published var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var microphoneEnabled = false
    @Published var errorMessage: String?
    @Published var selectedTodoID: String?
    @Published var selectedMemory: DrillDownResult?
    @Published var lastRefresh = Date()
    @Published var serviceBusy = false

    let paths: AppPaths
    private(set) var config: AppConfig
    private(set) var service: MemoryService?
    private var refreshTimer: Timer?
    private let refreshQueue = DispatchQueue(label: "com.privatesecretary.app.refresh", qos: .userInitiated)
    private let supervisor = ServiceSupervisor()

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        var loaded = AppConfig()
        var loadedService: MemoryService?
        do {
            loaded = try AppConfigLoader.loadOrCreate(paths: paths)
            loadedService = try MemoryService(paths: paths, config: loaded)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        self.config = loaded
        self.service = loadedService
        self.microphoneEnabled = loaded.capture.microphoneEnabled
        self.screenPermission = CGPreflightScreenCaptureAccess()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var isServiceRunning: Bool {
        status?.capture.state == "running"
    }

    var serviceStateLabel: String {
        guard let status else { return "Starting…" }
        switch status.capture.state {
        case "running": return "Running"
        case "capture_unavailable": return "Permission required"
        case "disabled": return "Capture disabled"
        case "stopped": return "Stopped"
        case "not_running": return "Not running"
        default: return status.capture.state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func refresh() {
        guard let service else { return }
        if isRefreshing { return }
        isRefreshing = true
        let day = selectedDate
        let filter = todoFilter
        let query = messageQuery
        let unread = unreadOnly
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.load(service: service, day: day, filter: filter, query: query, unread: unread)
            DispatchQueue.main.async {
                self.apply(result)
            }
        }
    }

    private struct LoadResult {
        var status: ServiceStatus?
        var brief: DailyBrief?
        var todos: [TodoItem] = []
        var contacts: [Contact] = []
        var messages: [ContactMessage] = []
        var error: String?
    }

    private static func load(
        service: MemoryService,
        day: Date,
        filter: TodoFilter,
        query: String,
        unread: Bool
    ) -> LoadResult {
        var result = LoadResult()
        do {
            result.status = try service.status()
            let brief = try service.brief(dayKey: DateCoding.dayKey(day))
            result.brief = brief
            result.todos = try service.todos(status: filter.status, limit: 500)
            result.contacts = try service.contacts(limit: 200)
            result.messages = try service.messages(
                unreadOnly: unread,
                query: query.isEmpty ? nil : query,
                limit: 300
            )
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    private func apply(_ result: LoadResult) {
        status = result.status
        brief = result.brief
        todos = result.todos
        contacts = result.contacts
        messages = result.messages
        errorMessage = result.error
        screenPermission = CGPreflightScreenCaptureAccess()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        isRefreshing = false
        lastRefresh = Date()
    }

    // MARK: - Local writes (never external actions)

    func addTodo(_ title: String, detail: String = "") {
        guard let service, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            _ = try service.addTodo(title: title, detail: detail)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTodo(_ todo: TodoItem, done: Bool) {
        guard let service else { return }
        do {
            _ = try service.updateTodo(id: todo.id, status: done ? .done : .open)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissTodo(_ todo: TodoItem) {
        guard let service else { return }
        do {
            _ = try service.updateTodo(id: todo.id, status: .dismissed)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ message: ContactMessage, read: Bool = true) {
        guard let service else { return }
        do {
            _ = try service.markMessageRead(id: message.id, isRead: read)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDrillDown(_ memoryID: String) {
        guard let service else { return }
        do {
            selectedMemory = try service.drillDown(memoryID: memoryID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateDigest() {
        guard let service else { return }
        do {
            _ = try service.generateDigest(dayKey: DateCoding.dayKey(selectedDate))
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Dashboard and system actions

    func copyDailyBrief() {
        guard let service else { return }
        do {
            let snapshot = try brief ?? service.brief(dayKey: DateCoding.dayKey(selectedDate))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ContextExporter.markdown(snapshot), forType: .string)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        config.capture.microphoneEnabled = enabled
        do {
            try AppConfigLoader.save(config, to: paths.configFile)
            microphoneEnabled = enabled
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDashboard() {
        guard let service else { return }
        do {
            let snapshot = try brief ?? service.brief(dayKey: DateCoding.dayKey(selectedDate))
            try FileManager.default.createDirectory(at: paths.exportsDirectory, withIntermediateDirectories: true)
            let url = paths.exportsDirectory.appendingPathComponent("dashboard-\(snapshot.date).html")
            try DashboardRenderer.render(snapshot).write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDataFolder() {
        NSWorkspace.shared.open(paths.home)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.screenPermission = CGPreflightScreenCaptureAccess()
            self?.refresh()
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    func startService(forceRestart: Bool = false) {
        serviceBusy = true
        let paths = self.paths
        let supervisor = self.supervisor
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String?
            do {
                try supervisor.start(paths: paths, forceRestart: forceRestart)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.serviceBusy = false
                self.errorMessage = message
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refresh() }
            }
        }
    }

    func restartService() {
        startService(forceRestart: true)
    }

    func stopService() {
        serviceBusy = true
        let supervisor = self.supervisor
        DispatchQueue.global(qos: .userInitiated).async {
            supervisor.stop()
            DispatchQueue.main.async {
                self.serviceBusy = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
            }
        }
    }
}
