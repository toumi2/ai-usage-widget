import AppKit
import ServiceManagement
import SwiftUI

struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Double?
    let resetsAt: Double?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct UsageSnapshot {
    let weekly: UsageWindow?
    let fiveHour: UsageWindow?
    let resetCredits: ResetCredits?
    let updatedAt: Date
}

enum UsageState {
    case loading
    case available(UsageSnapshot)
    case unavailable(String)
}

enum WidgetSize: String, CaseIterable, Identifiable {
    case tiny
    case mini
    case micro
    case nano
    case pico

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Tiny is the full-size layout; the smaller sizes shrink it evenly.
    var scale: CGFloat {
        switch self {
        case .tiny: return 1.0
        case .mini: return 0.9
        case .micro: return 0.8
        case .nano: return 0.7
        case .pico: return 0.6
        }
    }

    var dimensions: CGSize {
        CGSize(width: (240 * scale).rounded(), height: (78 * scale).rounded())
    }

    /// Older saved sizes (Small through Large) were all bigger than Tiny, so they map to Tiny.
    static var current: WidgetSize {
        WidgetSize(rawValue: UserDefaults.standard.string(forKey: "widget.size") ?? "tiny") ?? .tiny
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case thirtySeconds = 30
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .threeMinutes: return "3 minutes"
        case .fiveMinutes: return "5 minutes"
        }
    }

    static var current: RefreshInterval {
        RefreshInterval(rawValue: UserDefaults.standard.integer(forKey: "widget.refreshInterval")) ?? .oneMinute
    }
}

enum WidgetBackgroundMode: String, CaseIterable, Identifiable {
    case onHover
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onHover: return "On hover"
        case .always: return "Always"
        }
    }

    static var current: WidgetBackgroundMode {
        WidgetBackgroundMode(rawValue: UserDefaults.standard.string(forKey: "widget.backgroundMode") ?? "onHover") ?? .onHover
    }
}

@MainActor
final class UsageController: ObservableObject {
    static let shared = UsageController()

    @Published private(set) var states: [UsageProvider: UsageState] = [:]
    @Published private(set) var refreshing: Set<UsageProvider> = []
    @Published private(set) var provider: UsageProvider
    @Published private(set) var providerMode = ProviderMode.current
    @Published var size = WidgetSize.current
    @Published private(set) var refreshInterval = RefreshInterval.current
    @Published private(set) var backgroundMode = WidgetBackgroundMode.current
    @Published private(set) var startupEnabled = SMAppService.mainApp.status == .enabled

    var onSizeChange: ((WidgetSize) -> Void)?
    private var refreshTasks: [UsageProvider: Task<Void, Never>] = [:]
    private var lastUpdated: [UsageProvider: Date] = [:]
    private var pollingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var automaticProvider = UsageProvider.lastAutomatic
    private var settingsWindow: NSWindow?
#if DEBUG
    private(set) var isScreenshotPreview = false
#endif

    var state: UsageState { states[provider] ?? .loading }
    var isRefreshing: Bool { refreshing.contains(provider) }

    private init() {
        provider = ProviderMode.current.fixedProvider ?? UsageProvider.lastAutomatic
        schedulePolling()
        observeFrontmostApp()
    }

    private func schedulePolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// In Auto mode, follows Codex or Claude when either app comes to the front.
    private func observeFrontmostApp() {
        if let front = NSWorkspace.shared.frontmostApplication,
           let match = UsageProvider.matching(bundleIdentifier: front.bundleIdentifier) {
            automaticProvider = match
            if providerMode == .automatic { provider = match }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let match = UsageProvider.matching(bundleIdentifier: app?.bundleIdentifier) else { return }
            Task { @MainActor [weak self] in self?.frontAppChanged(to: match) }
        }
    }

    private func frontAppChanged(to match: UsageProvider) {
        automaticProvider = match
        UserDefaults.standard.set(match.rawValue, forKey: "widget.lastProvider")
        guard providerMode == .automatic else { return }
        show(match)
    }

    private func show(_ newProvider: UsageProvider) {
#if DEBUG
        if isScreenshotPreview { provider = newProvider; return }
#endif
        guard newProvider != provider else { return }
        provider = newProvider
        if isStale(newProvider) { refresh() }
    }

    func isStale(_ provider: UsageProvider) -> Bool {
        guard let updated = lastUpdated[provider] else { return true }
        return Date().timeIntervalSince(updated) > refreshInterval.seconds
    }

    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Usage Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(controller: self))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    /// Refreshes the provider the widget is showing.
    func refresh() {
        refresh(provider)
    }

    func refresh(_ target: UsageProvider) {
#if DEBUG
        if isScreenshotPreview { return }
#endif
        guard !refreshing.contains(target) else { return }
        refreshing.insert(target)
        if case .available = states[target] {
            // Keep the last reading visible while the next one loads.
        } else {
            states[target] = .loading
        }
        refreshTasks[target]?.cancel()
        refreshTasks[target] = Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .utility) { () throws -> UsageSnapshot in
                    switch target {
                    case .codex: return try CodexAppServerReader().readRateLimits()
                    case .claude: return try ClaudeUsageReader().readUsage()
                    }
                }.value
                guard !Task.isCancelled else { return }
                self?.states[target] = .available(snapshot)
                self?.lastUpdated[target] = snapshot.updatedAt
            } catch {
                guard !Task.isCancelled else { return }
                self?.states[target] = .unavailable(error.localizedDescription)
                self?.lastUpdated[target] = Date()
            }
            self?.refreshing.remove(target)
        }
    }

#if DEBUG
    func showScreenshotPreview() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isScreenshotPreview = true
        size = .tiny
        let now = Date()
        states[.claude] = .available(UsageSnapshot(
            weekly: UsageWindow(usedPercent: 38, windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400).timeIntervalSince1970),
            fiveHour: UsageWindow(usedPercent: 71, windowDurationMins: 300, resetsAt: now.addingTimeInterval(2 * 3_600).timeIntervalSince1970),
            resetCredits: nil,
            updatedAt: now
        ))
        if CommandLine.arguments.contains("--claude") { provider = .claude } else { provider = .codex }
        states[.codex] = .available(UsageSnapshot(
            weekly: UsageWindow(usedPercent: 64, windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400).timeIntervalSince1970),
            fiveHour: UsageWindow(usedPercent: 27, windowDurationMins: 300, resetsAt: now.addingTimeInterval(5 * 3_600).timeIntervalSince1970),
            resetCredits: ResetCredits(availableCount: 2, credits: [
                ResetCredit(status: "available", expiresAt: now.addingTimeInterval(7 * 86_400).timeIntervalSince1970),
                ResetCredit(status: "available", expiresAt: now.addingTimeInterval(14 * 86_400).timeIntervalSince1970)
            ]),
            updatedAt: now
        ))
    }
#endif

    func setSize(_ newSize: WidgetSize) {
        size = newSize
        UserDefaults.standard.set(newSize.rawValue, forKey: "widget.size")
        onSizeChange?(newSize)
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "widget.refreshInterval")
        schedulePolling()
    }

    func setProviderMode(_ mode: ProviderMode) {
        providerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "widget.providerMode")
        show(mode.fixedProvider ?? automaticProvider)
    }

    func setBackgroundMode(_ mode: WidgetBackgroundMode) {
        backgroundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "widget.backgroundMode")
    }

    func setStartupEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startupEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            startupEnabled = SMAppService.mainApp.status == .enabled
            let alert = NSAlert()
            alert.messageText = "Couldn’t update the startup setting"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

private enum UsageReaderError: LocalizedError {
    case commandNotFound
    case exited(String)
    case invalidResponse
    case missingLimits

    var errorDescription: String? {
        switch self {
        case .commandNotFound: return "Codex CLI wasn’t found. Install it and sign in, then refresh."
        case .exited(let details): return details.isEmpty ? "Codex app-server couldn’t start." : details
        case .invalidResponse: return "Codex returned a response the widget couldn’t read."
        case .missingLimits: return "Usage limits aren’t available for this Codex account right now."
        }
    }
}

struct CodexAppServerReader {

    func readRateLimits() throws -> UsageSnapshot {
        let codexURL = locateCodex()
        guard let codexURL else { throw UsageReaderError.commandNotFound }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = codexURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(codexURL.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, preferred in preferred }

        do { try process.run() } catch { throw UsageReaderError.exited(error.localizedDescription) }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        let reader = LineReader(handle: output.fileHandleForReading)
        do {
            try write(["method": "initialize", "id": 1, "params": [
                "clientInfo": ["name": "ai-usage-widget", "version": "1.1.0"],
                "capabilities": ["experimentalApi": true]
            ]], to: input)
            _ = try reader.readResponse(id: 1)
            try write(["method": "initialized"], to: input)
            try write(["method": "account/rateLimits/read", "id": 2], to: input)
            let response = try reader.readResponse(id: 2)
            guard let result = response["result"] as? [String: Any] else {
                let message = (response["error"] as? [String: Any])?["message"] as? String
                throw UsageReaderError.exited(message ?? UsageReaderError.invalidResponse.localizedDescription)
            }
            return try decodeSnapshot(result)
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let diagnosticData = errors.fileHandleForReading.readDataToEndOfFile().prefix(512)
            let diagnostic = String(decoding: diagnosticData, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)
            if let diagnostic, !diagnostic.isEmpty {
                throw UsageReaderError.exited(diagnostic)
            }
            if process.terminationStatus != 0 {
                throw UsageReaderError.exited("Codex app-server stopped (exit \(process.terminationStatus)).")
            }
            throw error
        }
    }

    private func locateCodex() -> URL? {
        let fileManager = FileManager.default
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            candidates += ["\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex"]
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates.map(URL.init(fileURLWithPath:)).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func write(_ message: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        pipe.fileHandleForWriting.write(data + Data([0x0A]))
    }

    private func decodeSnapshot(_ result: [String: Any]) throws -> UsageSnapshot {
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = (byLimit?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        guard let limits else { throw UsageReaderError.missingLimits }
        let windows = [limits["primary"] as? [String: Any], limits["secondary"] as? [String: Any]]
            .compactMap { $0 }
            .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .compactMap { try? JSONDecoder().decode(UsageWindow.self, from: $0) }

        let weekly = windows.first { ($0.windowDurationMins ?? 0) >= 1_440 }
        let fiveHour = windows.first { ($0.windowDurationMins ?? 0) > 0 && ($0.windowDurationMins ?? 0) < 1_440 }
        guard weekly != nil || fiveHour != nil else { throw UsageReaderError.missingLimits }
        let resetCredits = (result["rateLimitResetCredits"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(ResetCredits.self, from: $0) }
        return UsageSnapshot(weekly: weekly, fiveHour: fiveHour, resetCredits: resetCredits, updatedAt: Date())
    }
}

private struct LineReader {
    let handle: FileHandle

    func readResponse(id: Int) throws -> [String: Any] {
        while let line = try readLine() {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if (object["id"] as? Int) == id { return object }
        }
        throw UsageReaderError.invalidResponse
    }

    private func readLine() throws -> String? {
        var bytes = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { return bytes.isEmpty ? nil : String(data: bytes, encoding: .utf8) }
            if byte[0] == 0x0A { return String(data: bytes, encoding: .utf8) }
            bytes.append(byte[0])
        }
    }
}
