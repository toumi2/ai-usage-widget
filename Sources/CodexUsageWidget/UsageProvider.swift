import Foundation

/// The service whose usage the widget is showing.
enum UsageProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    /// Maps a frontmost app to a provider. Other apps return nil so the widget keeps its last choice.
    static func matching(bundleIdentifier: String?) -> UsageProvider? {
        guard let bundleIdentifier = bundleIdentifier?.lowercased() else { return nil }
        if bundleIdentifier == "com.anthropic.claudefordesktop" || bundleIdentifier.hasPrefix("com.anthropic.") {
            return .claude
        }
        if bundleIdentifier == "com.openai.codex" || bundleIdentifier == "com.openai.chat" {
            return .codex
        }
        return nil
    }

    static var lastAutomatic: UsageProvider {
        UsageProvider(rawValue: UserDefaults.standard.string(forKey: "widget.lastProvider") ?? "codex") ?? .codex
    }
}

/// How the widget picks a provider.
enum ProviderMode: String, CaseIterable, Identifiable {
    case automatic
    case codex
    case claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Auto (follow front app)"
        case .codex: return "Always Codex"
        case .claude: return "Always Claude"
        }
    }

    var fixedProvider: UsageProvider? {
        switch self {
        case .automatic: return nil
        case .codex: return .codex
        case .claude: return .claude
        }
    }

    static var current: ProviderMode {
        ProviderMode(rawValue: UserDefaults.standard.string(forKey: "widget.providerMode") ?? "automatic") ?? .automatic
    }
}
