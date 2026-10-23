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
    case small
    case compact
    case regular
    case large

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var dimensions: CGSize {
        switch self {
        case .tiny: return CGSize(width: 240, height: 78)
        case .small: return CGSize(width: 264, height: 82)
        case .compact: return CGSize(width: 286, height: 86)
        case .regular: return CGSize(width: 326, height: 96)
        case .large: return CGSize(width: 376, height: 112)
        }
    }

    static var current: WidgetSize {
        WidgetSize(rawValue: UserDefaults.standard.string(forKey: "widget.size") ?? "regular") ?? .regular
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

    @Published private(set) var state: UsageState = .loading
    @Published var isRefreshing = false
    @Published var size = WidgetSize.current
    @Published private(set) var refreshInterval = RefreshInterval.current
    @Published private(set) var backgroundMode = WidgetBackgroundMode.current
    @Published private(set) var startupEnabled = SMAppService.mainApp.status == .enabled

    var onSizeChange: ((WidgetSize) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var pollingTimer: Timer?
    private var settingsWindow: NSWindow?
#if DEBUG
    private(set) var isScreenshotPreview = false
#endif

    private init() {
        schedulePolling()
    }

    private func schedulePolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Usage Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(controller: self))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if case .available = state {
            // Keep the last reading visible while Codex returns the next one.
        } else {
            state = .loading
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try CodexAppServerReader().readRateLimits()
                }.value
                guard !Task.isCancelled else { return }
                self?.state = .available(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .unavailable(error.localizedDescription)
            }
            self?.isRefreshing = false
        }
    }

#if DEBUG
    func showScreenshotPreview() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        isScreenshotPreview = true
        size = .regular
        let now = Date()
        state = .available(UsageSnapshot(
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

private struct CodexAppServerReader {

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
                "clientInfo": ["name": "codex-usage-widget", "version": "1.0.0"],
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
