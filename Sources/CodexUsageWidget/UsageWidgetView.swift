import AppKit
import SwiftUI

struct UsageWidgetView: View {
    @ObservedObject var controller: UsageController
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: px(2)) {
            HStack(spacing: px(7)) {
                WindowDragHandle()
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        HStack(spacing: px(6)) {
                            Text(headerLabel)
                                .font(.system(size: px(10), weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.82))
                                .shadow(color: .black.opacity(0.62), radius: 0.8, x: 0, y: 0.5)
                                .lineLimit(1)
                            if isHovered {
                                Image(systemName: "hand.draw")
                                    .font(.system(size: px(12), weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .help(resetCreditHelp)
                if isHovered {
                    controlButton("arrow.clockwise", label: "Refresh usage") { controller.refresh() }
                    controlButton("slider.horizontal.3", label: "Settings") { controller.showSettings() }
                    controlButton("xmark", label: "Quit AI Usage") { NSApp.terminate(nil) }
                }
            }
            .frame(height: px(18))
            usageRow(title: "Weekly", window: snapshot?.weekly)
            usageRow(title: "5 hour", window: snapshot?.fiveHour)
        }
        .padding(.horizontal, px(12))
        .padding(.vertical, px(4))
        .frame(width: controller.size.dimensions.width, height: controller.size.dimensions.height)
        .onHover { hovering in
            isHovered = hovering
            if hovering, canRefreshOnHover, controller.isStale(controller.provider) {
                controller.refresh()
            }
        }
        .background {
            widgetGlassBackground
                .opacity(isWidgetBackgroundVisible ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.16), value: isWidgetBackgroundVisible)
        .accessibilityElement(children: .contain)
    }

    private var snapshot: UsageSnapshot? {
        if case .available(let snapshot) = controller.state { return snapshot }
        return nil
    }

    /// All sizes use the compact layout; smaller sizes scale it down.
    private var isNarrow: Bool { true }

    private func px(_ value: CGFloat) -> CGFloat {
        (value * controller.size.scale).rounded(.toNearestOrAwayFromZero)
    }

    /// "Codex · 2 resets" or "Claude". Reset credits only exist for Codex.
    private var headerLabel: String {
        switch controller.provider {
        case .codex: return "Codex · " + (snapshot?.resetCredits?.label ?? "Resets —")
        case .claude:
            if case .unavailable(let message) = controller.state {
                return message.contains("signed in") || message.contains("wasn’t found")
                    ? "Claude · sign in: run claude in Terminal"
                    : "Claude · unavailable"
            }
            return "Claude · " + (snapshot?.resetCredits?.label ?? "Resets —")
        }
    }

    private var resetCreditHelp: String {
        let details: String
        switch controller.provider {
        case .codex:
            details = snapshot?.resetCredits?.hoverDetails
                ?? "Reset-credit information is not available from Codex."
        case .claude:
            details = (snapshot?.resetCredits?.hoverDetails ?? "Reset-credit information is not available yet.")
                + "\nClaude plan limits from the signed-in Claude Code CLI. Reset credits come from Claude’s usage service using Claude Code’s saved login."
        }
        let switching = controller.providerMode == .automatic
            ? "\nSwitches automatically when Codex or Claude is the front app."
            : ""
        return details + switching + "\n\nDrag this area to move the widget."
    }

    private var isWidgetBackgroundVisible: Bool {
        controller.backgroundMode == .always || isHovered
    }

    @ViewBuilder
    private var widgetGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: px(14), style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.clear, in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay { shape.fill(Color.black.opacity(0.42)) }
                .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75) }
        }
    }

    private var canRefreshOnHover: Bool {
#if DEBUG
        !controller.isScreenshotPreview
#else
        true
#endif
    }

    @ViewBuilder
    private func usageRow(title: String, window: UsageWindow?) -> some View {
        VStack(spacing: px(2)) {
            HStack(alignment: .firstTextBaseline, spacing: px(5)) {
                Text(title)
                    .font(.system(size: px(12), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.62), radius: 0.8, x: 0, y: 0.5)
                Text(window.map { "\(Int($0.remainingPercent.rounded()))% left" } ?? "—")
                    .font(.system(size: px(11), weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color(for: window?.remainingPercent))
                    .shadow(color: .black.opacity(0.4), radius: 0.5, x: 0, y: 0.5)
                    .lineLimit(1)
                Spacer(minLength: px(8))
                Text(resetLabel(for: window))
                    .font(.system(size: px(10), weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .shadow(color: .black.opacity(0.62), radius: 0.8, x: 0, y: 0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(color(for: window?.remainingPercent))
                        .frame(width: max(0, geometry.size.width * min(max((window?.remainingPercent ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: px(5))
            .shadow(color: color(for: window?.remainingPercent).opacity(0.18), radius: 4, y: 1)
        }
        .frame(maxHeight: .infinity)
        .help(rowHelp(window: window))
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: px(11), weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: px(18), height: px(18))
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func color(for percentage: Double?) -> Color {
        guard let percentage else { return Color.secondary.opacity(0.55) }
        if percentage <= 20 { return Color(red: 0.96, green: 0.38, blue: 0.36) }
        if percentage <= 50 { return Color(red: 0.96, green: 0.68, blue: 0.31) }
        return Color(red: 0.30, green: 0.78, blue: 0.56)
    }

    private func resetLabel(for window: UsageWindow?) -> String {
        guard let timestamp = window?.resetsAt else { return "Reset unavailable" }
        let countdown = UsageTimeFormatting.countdown(until: timestamp)
        if countdown == "unavailable" { return "Reset unavailable" }
        if countdown == "now" { return isNarrow ? "now" : "Resets now" }
        return isNarrow ? "in \(countdown)" : "Resets in \(countdown)"
    }

    private func rowHelp(window: UsageWindow?) -> String {
        if let window, let date = window.resetsAt {
            let updated = snapshot?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "unknown"
            return "\(Int(window.remainingPercent.rounded()))% remaining. Updated \(updated). Resets at \(Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .shortened))"
        }
        if case .unavailable(let message) = controller.state { return message }
        return "Usage data unavailable. Use the refresh control to try again."
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
