import AppKit
import SwiftUI

@main
@MainActor
enum CodexUsageWidgetApp {
    private static var delegate: AppDelegate?

    static func main() {
#if DEBUG
        if CommandLine.arguments.contains("--probe-claude") {
            // Debug aid: read Claude usage once, print it and exit.
            do {
                let snapshot = try ClaudeUsageReader().readUsage()
                print("5 hour: \(snapshot.fiveHour.map { "\($0.usedPercent)% used, resets \($0.resetsAt.map { Date(timeIntervalSince1970: $0) }.map(String.init(describing:)) ?? "?")" } ?? "none")")
                print("Weekly: \(snapshot.weekly.map { "\($0.usedPercent)% used, resets \($0.resetsAt.map { Date(timeIntervalSince1970: $0) }.map(String.init(describing:)) ?? "?")" } ?? "none")")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }
#endif
        let application = NSApplication.shared
        delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetWindow: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
#if DEBUG
        let isScreenshotPreview = CommandLine.arguments.contains("--screenshot-preview")
        if isScreenshotPreview {
            UsageController.shared.showScreenshotPreview()
        } else {
            UsageController.shared.refresh()
        }
#else
        UsageController.shared.refresh()
#endif

        let size = UsageController.shared.size.dimensions
#if DEBUG
        let frame: NSRect
        if isScreenshotPreview, let screen = NSScreen.main?.visibleFrame {
            frame = NSRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        } else {
            frame = restoredFrame(size: size)
        }
#else
        let frame = restoredFrame(size: size)
#endif
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Usage"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: UsageWidgetView(controller: .shared))
        window.setContentSize(size)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        widgetWindow = window
        installStatusItem()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let origin = window?.frame.origin else { return }
            UserDefaults.standard.set(origin.x, forKey: "widget.origin.x")
            UserDefaults.standard.set(origin.y, forKey: "widget.origin.y")
        }
        UsageController.shared.onSizeChange = { [weak self] size in
            self?.resizeWidget(to: size.dimensions)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusBarIcon.makeImage()
        item.button?.toolTip = "Codex Usage"

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Widget", action: #selector(showWidget), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let refresh = NSMenuItem(title: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Codex Usage", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func showWidget() {
        widgetWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshUsage() {
        UsageController.shared.refresh()
    }

    @objc private func showSettings() {
        UsageController.shared.showSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func restoredFrame(size: CGSize) -> NSRect {
        let defaults = UserDefaults.standard
        let savedX = defaults.object(forKey: "widget.origin.x") as? Double
        let savedY = defaults.object(forKey: "widget.origin.y") as? Double
        let screens = NSScreen.screens.map(\.visibleFrame)
        let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let savedOrigin = CGPoint(
            x: savedX ?? (fallback.maxX - size.width - 28),
            y: savedY ?? (fallback.minY + 48)
        )
        let candidate = NSRect(origin: savedOrigin, size: size)
        let screen = screens.first(where: { $0.intersects(candidate) }) ?? fallback
        let maxX = max(screen.minX, screen.maxX - size.width)
        let maxY = max(screen.minY, screen.maxY - size.height)
        let origin = CGPoint(
            x: min(max(savedOrigin.x, screen.minX), maxX),
            y: min(max(savedOrigin.y, screen.minY), maxY)
        )
        return NSRect(origin: origin, size: size)
    }

    private func resizeWidget(to size: CGSize) {
        guard let window = widgetWindow else { return }
        let oldFrame = window.frame
        let newFrame = NSRect(
            x: oldFrame.maxX - size.width,
            y: oldFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(newFrame, display: true, animate: true)
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }
}
