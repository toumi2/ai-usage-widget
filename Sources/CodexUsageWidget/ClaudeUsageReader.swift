import Darwin
import Foundation

enum ClaudeReaderError: LocalizedError, Equatable {
    case commandNotFound
    case notSignedIn
    case failed(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .commandNotFound:
            return "Claude Code CLI wasn’t found. Install it, run `claude` once in Terminal and sign in, then refresh."
        case .notSignedIn:
            return "Claude Code CLI isn’t signed in. Run `claude` in Terminal, sign in, then refresh."
        case .failed(let message):
            return message
        case .unreadable:
            return "Claude’s /usage screen couldn’t be read. Check that `claude` works in Terminal, then refresh."
        }
    }
}

/// Reads Claude plan limits by running the signed-in `claude` CLI in a pseudo-terminal
/// and capturing its `/usage` screen. It never reads credentials and sends no prompt to the model.
struct ClaudeUsageReader {
    var timeout: TimeInterval = 25

    func readUsage() throws -> UsageSnapshot {
        guard let claudeURL = Self.locateClaude() else { throw ClaudeReaderError.commandNotFound }
        if Self.isSignedIn(claudeURL: claudeURL) == false { throw ClaudeReaderError.notSignedIn }
        let screen = try capture(claudeURL: claudeURL)
        return try ClaudeUsageParser.parse(screen: screen, now: Date())
    }

    static func locateClaude() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let home = environment["HOME"] {
            candidates += [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "\(home)/.npm-global/bin/claude",
                "\(home)/.bun/bin/claude"
            ]
        }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        return candidates.map(URL.init(fileURLWithPath:)).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// The CLI finds its saved login by user name, so make sure USER and LOGNAME are set.
    static func cliEnvironment(claudeURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" {
            environment.removeValue(forKey: key)
        }
        if environment["USER"]?.isEmpty ?? true { environment["USER"] = NSUserName() }
        if environment["LOGNAME"]?.isEmpty ?? true { environment["LOGNAME"] = NSUserName() }
        if environment["HOME"]?.isEmpty ?? true { environment["HOME"] = NSHomeDirectory() }
        environment["PATH"] = "\(claudeURL.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    /// Asks `claude auth status` (JSON, no network prompt). Returns nil when the answer is unclear.
    static func isSignedIn(claudeURL: URL) -> Bool? {
        let process = Process()
        let output = Pipe()
        process.executableURL = claudeURL
        process.arguments = ["auth", "status"]
        process.environment = cliEnvironment(claudeURL: claudeURL)
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = probeDirectory()
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["loggedIn"] as? Bool
    }

    /// A private, empty working folder so the CLI loads no project files.
    private static func probeDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("AI Usage/ClaudeProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Debug aid: set CODEX_USAGE_CLAUDE_DUMP to a file path to save the raw screen.
    private func dump(_ data: Data) {
        guard let path = ProcessInfo.processInfo.environment["CODEX_USAGE_CLAUDE_DUMP"] else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func capture(claudeURL: URL) throws -> String {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw ClaudeReaderError.failed("Couldn’t open a terminal for the Claude CLI.")
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let process = Process()
        process.executableURL = claudeURL
        process.arguments = [
            "--allowed-tools", "",
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#
        ]
        process.currentDirectoryURL = Self.probeDirectory()
        var environment = Self.cliEnvironment(claudeURL: claudeURL)
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do { try process.run() } catch {
            throw ClaudeReaderError.failed("Claude CLI couldn’t start: \(error.localizedDescription)")
        }
        try? slaveHandle.close()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? masterHandle.close()
        }

        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        var output = Data()
        var sentUsage = false
        var answeredTrust = false
        var onboardingEnters = 0
        var lastOnboardingEnter = Date.distantPast
        var lastEnter = Date.distantPast
        var finishedAt: Date?
        let start = Date()

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
        }

        while Date().timeIntervalSince(start) < timeout {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 200) > 0 {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = read(master, &buffer, buffer.count)
                if count > 0 { output.append(contentsOf: buffer[0..<count]) }
                if count == 0 { break }
            }
            if !process.isRunning { break }

            let text = ClaudeUsageParser.clean(String(decoding: output, as: UTF8.self))
            let compact = ClaudeUsageParser.compact(text)

            if ClaudeUsageParser.looksSignedOut(compact) {
                dump(output)
                throw ClaudeReaderError.notSignedIn
            }
            // Folder trust prompt for the app's own empty folder. "No, exit" is preselected,
            // so move down to "Yes, I trust this folder" before confirming.
            if !answeredTrust && (compact.contains("trustthisfolder") || compact.contains("trustthefiles")) {
                answeredTrust = true
                usleep(300_000)
                send("\u{1B}[B")
                usleep(300_000)
                send("\r")
                continue
            }
            // First-run screens of a signed-in CLI (theme picker, notes): accept the defaults.
            if !sentUsage, ClaudeUsageParser.isOnboardingScreen(ClaudeUsageParser.compact(ClaudeUsageParser.lastScreen(text))),
               onboardingEnters < 6, Date().timeIntervalSince(lastOnboardingEnter) > 1.5 {
                onboardingEnters += 1
                lastOnboardingEnter = Date()
                send("\r")
                continue
            }
            let elapsed = Date().timeIntervalSince(start)
            let tail = ClaudeUsageParser.compact(ClaudeUsageParser.lastScreen(text))
            let promptReady = !ClaudeUsageParser.isOnboardingScreen(tail)
                && (tail.contains("forshortcuts") || tail.contains("tryedit") || elapsed > 10)
            if !sentUsage && promptReady {
                sentUsage = true
                send("/usage")
                usleep(400_000)
                send("\r")
                lastEnter = Date()
                continue
            }
            if sentUsage {
                let panel = ClaudeUsageParser.lastPanel(text)
                if finishedAt == nil, ClaudeUsageParser.panelLooksComplete(panel)
                    || compact.contains("failedtoloadusage") {
                    finishedAt = Date()
                }
                if let finishedAt, Date().timeIntervalSince(finishedAt) > 1.2 { break }
                // The slash-command menu sometimes needs a second Enter.
                if finishedAt == nil, Date().timeIntervalSince(lastEnter) > 3 {
                    send("\r")
                    lastEnter = Date()
                }
            }
        }
        send("\u{1B}")
        dump(output)
        return ClaudeUsageParser.clean(String(decoding: output, as: UTF8.self))
    }
}

/// Turns the text of Claude Code's `/usage` screen into a snapshot. Pure functions, covered by tests.
enum ClaudeUsageParser {
    /// Removes terminal control sequences. Cursor-forward moves become spaces so words stay apart.
    static func clean(_ raw: String) -> String {
        var text = raw
        text = replace(#"\x{1B}\[(\d*)C"#, in: text) { match in
            String(repeating: " ", count: max(1, Int(match[1]) ?? 1))
        }
        text = replace(#"\x{1B}\[\d*(?:;\d*)?[Hf]|\x{1B}\[\d*[ABEFG]"#, in: text) { _ in "\n" }
        text = replace(#"\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)"#, in: text) { _ in "" }
        text = replace(#"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]"#, in: text) { _ in "" }
        text = replace(#"\x{1B}[()][A-Za-z0-9]|\x{1B}[=>78]|\x{1B}"#, in: text) { _ in "" }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return text
    }

    static func compact(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    static func isOnboardingScreen(_ compact: String) -> Bool {
        ["choosethetextstyle", "securitynotes", "pressentertocontinue", "usetheseterminalsettings"].contains { compact.contains($0) }
    }

    /// Roughly the most recent screenful, so old frames don't keep matching.
    static func lastScreen(_ text: String) -> String {
        String(text.suffix(3_000))
    }

    static func looksSignedOut(_ compact: String) -> Bool {
        ["selectloginmethod", "notloggedin", "pleaserun/login",
         "authentication_error", "token_expired", "invalidapikey"].contains { compact.contains($0) }
    }

    /// The text after the last time the usage panel was drawn.
    static func lastPanel(_ text: String) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: "current session", options: .backwards)
            ?? lower.range(of: "currentsession", options: .backwards) else { return "" }
        return String(text[range.lowerBound...])
    }

    static func panelLooksComplete(_ panel: String) -> Bool {
        let lines = panel.split(whereSeparator: \.isNewline).map { compact(String($0)) }
        guard let week = lines.lastIndex(where: { $0.contains("currentweek") }) else { return false }
        return lines[week...].contains { $0.contains("%") } && lines[week...].contains { $0.contains("reset") }
    }

    static func parse(screen: String, now: Date, timeZone: TimeZone = .current) throws -> UsageSnapshot {
        let lowerCompact = compact(screen)
        if looksSignedOut(lowerCompact) { throw ClaudeReaderError.notSignedIn }

        let panel = lastPanel(screen)
        let lines = panel.split(whereSeparator: \.isNewline).map(String.init)
        let session = window(after: { $0.contains("currentsession") }, in: lines, minutes: 300, now: now, timeZone: timeZone)
        let week = window(after: { label in
            label.contains("currentweek") && (!label.contains("(") || label.contains("allmodels"))
        }, in: lines, minutes: 10_080, now: now, timeZone: timeZone)

        if session == nil && week == nil {
            if lowerCompact.contains("failedtoloadusage") {
                throw ClaudeReaderError.failed("Claude couldn’t load usage data right now. Try again shortly.")
            }
            if lowerCompact.contains("ratelimit") {
                throw ClaudeReaderError.failed("Claude is rate limiting usage checks. Try again in a few minutes.")
            }
            throw ClaudeReaderError.unreadable
        }
        return UsageSnapshot(weekly: week, fiveHour: session, resetCredits: resetCredits(in: panel), updatedAt: now)
    }

    /// Claude's /usage screen doesn't list reset credits today, so the count is 0 unless the
    /// screen says otherwise (for example "2 resets available" or "1 limit reset left").
    static func resetCredits(in panel: String) -> ResetCredits {
        let text = compact(panel)
        let pattern = #"(\d{1,2})(?:limit|usage)?resets?(?:credits?)?(?:available|left|remaining)"#
        if let match = firstMatch(pattern, in: text), let count = Int(match[1]) {
            return ResetCredits(availableCount: count, credits: nil)
        }
        return ResetCredits(availableCount: 0, credits: nil)
    }

    private static let labelMarkers = ["currentsession", "currentweek", "extrausage", "currentmonth"]

    private static func window(
        after isLabel: (String) -> Bool, in lines: [String], minutes: Double, now: Date, timeZone: TimeZone
    ) -> UsageWindow? {
        guard let start = lines.lastIndex(where: { isLabel(compact($0)) }) else { return nil }
        var used: Double?
        var reset: Double?
        for (offset, line) in lines[start...].enumerated() {
            let lineCompact = compact(line)
            if offset > 0, labelMarkers.contains(where: lineCompact.contains) { break }
            if used == nil, let value = percentUsed(in: lineCompact) { used = value }
            if reset == nil, lineCompact.contains("reset") {
                reset = resetDate(from: line, now: now, timeZone: timeZone)?.timeIntervalSince1970
            }
            if used != nil && reset != nil { break }
        }
        guard let used else { return nil }
        return UsageWindow(usedPercent: used, windowDurationMins: minutes, resetsAt: reset)
    }

    /// Reads "42% used" or "58% left". A bare percentage counts as used, the CLI's default wording.
    static func percentUsed(in compactLine: String) -> Double? {
        guard let match = firstMatch(#"([0-9]{1,3}(?:\.[0-9]+)?)%"#, in: compactLine),
              let value = Double(match[1]), value <= 100 else { return nil }
        let after = compactLine[compactLine.range(of: match[0])!.upperBound...]
        if after.hasPrefix("left") || after.hasPrefix("remaining") || after.hasPrefix("available") {
            return 100 - value
        }
        return value
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Parses reset text such as "Resets 3pm (Europe/Paris)", "Resets Oct 28, 10:30am (America/New_York)"
    /// or "Resets in 2h 15m". Works whether or not the terminal output kept its spaces.
    static func resetDate(from line: String, now: Date, timeZone fallbackZone: TimeZone = .current) -> Date? {
        guard let resetRange = line.range(of: "reset", options: .caseInsensitive) else { return nil }
        var text = String(line[resetRange.upperBound...])
        var zone = fallbackZone
        if let match = firstMatch(#"\(([^)]+)\)"#, in: text) {
            if let parsed = TimeZone(identifier: match[1].trimmingCharacters(in: .whitespaces)) { zone = parsed }
            text = text.replacingOccurrences(of: match[0], with: " ")
        }
        var body = compact(text)
        if body.hasPrefix("s") { body.removeFirst() } // "Resets" → drop the trailing s
        if body.hasPrefix(":") { body.removeFirst() }

        if body.hasPrefix("in"),
           firstMatch(#"^in(?:(\d+)d(?:ays?)?)?(?:(\d+)h(?:rs?|ours?)?)?(?:(\d+)m(?:ins?|inutes?)?)?"#, in: body) != nil {
            let match = firstMatch(#"^in(?:(\d+)d(?:ays?)?)?(?:(\d+)h(?:rs?|ours?)?)?(?:(\d+)m(?:ins?|inutes?)?)?"#, in: body)!
            let days = Double(match[1]) ?? 0, hours = Double(match[2]) ?? 0, mins = Double(match[3]) ?? 0
            guard days + hours + mins > 0 else { return nil }
            return now.addingTimeInterval(days * 86_400 + hours * 3_600 + mins * 60)
        }

        let pattern = #"^(?:on)?(?:([a-z]{3})[a-z]*\.?(\d{1,2})(?:st|nd|rd|th)?,?(?:(\d{4}),?)?)?(?:at)?(\d{1,2})(?:[:.](\d{2}))?(am|pm)?"#
        guard let match = firstMatch(pattern, in: body), !match[4].isEmpty, let hourValue = Int(match[4]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var hour = hourValue
        let minute = Int(match[5]) ?? 0
        switch match[6] {
        case "pm": if hour < 12 { hour += 12 }
        case "am": if hour == 12 { hour = 0 }
        default: break
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        if !match[1].isEmpty {
            guard let month = months.firstIndex(of: match[1]), let day = Int(match[2]) else { return nil }
            components.month = month + 1
            components.day = day
            if let year = Int(match[3]) { components.year = year }
            guard var date = calendar.date(from: components) else { return nil }
            if match[3].isEmpty, date < now.addingTimeInterval(-86_400) {
                date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }
        guard var date = calendar.date(from: components) else { return nil }
        if date < now.addingTimeInterval(-60) {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    // MARK: Regex helpers

    /// Returns the whole match followed by each capture group; missing groups are empty strings.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
