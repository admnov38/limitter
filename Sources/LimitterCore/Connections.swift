import Foundation
import CoreFoundation
import Darwin

public enum LimitsParser {
    public static func codex(_ result: [String: Any], now: Date = Date()) -> ProviderLimits {
        var snapshot = ProviderLimits(provider: .codex, source: "Codex account")
        var entries = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if entries.isEmpty, let legacy = result["rateLimits"] as? [String: Any] { entries["codex"] = legacy }
        let keys = entries.keys.sorted { a, b in a == "codex" ? b != "codex" : b == "codex" ? false : a < b }
        for key in keys {
            guard let value = entries[key] else { continue }
            if snapshot.plan == nil { snapshot.plan = value["planType"] as? String }
            let windows = ["primary", "secondary"].compactMap { name -> LimitWindow? in
                guard let window = value[name] as? [String: Any], let used = window["usedPercent"] as? NSNumber else { return nil }
                return LimitWindow(id: name, usedPercent: used.doubleValue,
                    durationMinutes: (window["windowDurationMins"] as? NSNumber)?.intValue,
                    resetsAt: (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }
            snapshot.buckets.append(LimitBucket(id: key, name: value["limitName"] as? String ?? (key == "codex" ? "All models" : key), windows: windows))
        }
        snapshot.resetCredits = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        snapshot.updatedAt = now
        return snapshot
    }
    public static func claude(_ data: [String: Any], updatedAt: Date) -> ProviderLimits {
        var snapshot = ProviderLimits(provider: .claude, source: "Claude status line")
        let limits = data["rate_limits"] as? [String: Any] ?? [:]
        let observed = data["window_captured_at"] as? [String: Any] ?? [:]
        snapshot.windowErrors = data["window_errors"] as? [String: String] ?? [:]
        let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, duration -> LimitWindow? in
            guard let raw = limits[key], !(raw is NSNull) else { return nil }
            if let value = raw as? [String: Any], value["used_percentage"] == nil || value["used_percentage"] is NSNull { return nil }
            guard let value = raw as? [String: Any], let used = ClaudeQuotaCache.percentage(value["used_percentage"]) else {
                snapshot.windowErrors[duration == 300 ? "Session" : "Weekly"] = "Claude sent an unreadable \(duration == 300 ? "session" : "weekly") quota. Waiting for a valid update."
                return nil
            }
            return LimitWindow(id: key, usedPercent: used, durationMinutes: duration,
                resetsAt: ClaudeQuotaCache.timestamp(value["resets_at"]).map { Date(timeIntervalSince1970: $0) }, observedAt: ClaudeQuotaCache.timestamp(observed[key]).map { Date(timeIntervalSince1970: $0) } ?? updatedAt)
        }
        snapshot.buckets = windows.isEmpty ? [] : [LimitBucket(id: "claude", name: "All models", windows: windows)]
        snapshot.updatedAt = updatedAt
        snapshot.receivedAt = ClaudeQuotaCache.timestamp(data["received_at"]).map { Date(timeIntervalSince1970: $0) } ?? updatedAt
        return snapshot
    }
}

public enum ConnectionError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

// Only read-only account requests are sent. Codex owns authentication; no credentials are read by Limitter.
public final class CodexConnection: @unchecked Sendable {
    public init() {}
    public static func executable() -> URL? {
        executable(home: FileManager.default.homeDirectoryForCurrentUser,
                   applicationDirectories: [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
                   path: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }
    static func executable(home: URL, applicationDirectories: [URL], path: String) -> URL? {
        // Finder-launched apps have a minimal PATH. Discover the CLI inside the desktop
        // bundle, including the nested, signed CLI shipped by current ChatGPT/Codex.
        let bundled = applicationDirectories.flatMap { directory in
            ["Codex.app", "ChatGPT.app"].flatMap { app in
                ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex-cli/bin/codex", "codex"].map {
                    directory.appendingPathComponent(app + "/Contents/Resources/" + $0)
                }
            }
        }
        let candidates = bundled + [URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex"), home.appendingPathComponent(".local/bin/codex")]
            + path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public func fetch() throws -> ProviderLimits {
        guard let executable = Self.executable() else { throw ConnectionError.unavailable("Install Codex and sign in to connect your limits.") }
        let rpc = RPCProcess(executable: executable)
        try rpc.start()
        defer { rpc.stop() }
        _ = try rpc.request(id: 0, method: "initialize", params: ["clientInfo": ["name": "limitter", "title": "Limitter", "version": "1.0.0"]])
        try rpc.send(["method": "initialized", "params": [:]])
        let limits = try rpc.request(id: 1, method: "account/rateLimits/read")
        var snapshot = LimitsParser.codex(limits)
        if let usage = try? rpc.request(id: 2, method: "account/usage/read"), let summary = usage["summary"] as? [String: Any] {
            snapshot.lifetimeTokens = summary["lifetimeTokens"] as? Int
            snapshot.streakDays = summary["currentStreakDays"] as? Int
        }
        return snapshot
    }
}

final class RPCProcess: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var buffer = Data(), replies: [Int: [String: Any]] = [:]
    private let provider: String
    private let jsonRPC: Bool
    private let claudeControl: Bool
    init(executable: URL, arguments: [String] = ["app-server"], provider: String = "Codex", jsonRPC: Bool = false, claudeControl: Bool = false) {
        self.provider = provider; self.jsonRPC = jsonRPC; self.claudeControl = claudeControl
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    }
    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if self.claudeControl, object["type"] as? String == "control_response", let response = object["response"] as? [String: Any],
                       let requestID = response["request_id"] as? String, let id = Int(requestID) {
                        self.replies[id] = response["subtype"] as? String == "success" ? ["result": response["response"] ?? [:]] : ["error": ["code": -1]]
                        self.signal.signal()
                    } else if let id = object["id"] as? Int { self.replies[id] = object; self.signal.signal() }
                }
                self.buffer.removeSubrange(...newline)
            }
            self.lock.unlock()
        }
        do { try process.run() } catch { stop(); throw ConnectionError.unavailable("Couldn’t start \(provider). Check your installation.") }
    }
    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func request(id: Int, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        var request: [String: Any] = ["id": id, "method": method, "params": params]
        if jsonRPC { request["jsonrpc"] = "2.0" }
        if claudeControl {
            var payload = params; payload["subtype"] = method
            request = ["type": "control_request", "request_id": String(id), "request": payload]
        }
        try send(request)
        let deadline = DispatchTime.now() + 10
        while true {
            lock.lock(); let response = replies.removeValue(forKey: id); lock.unlock()
            if let response {
                if let error = response["error"] as? [String: Any] {
                    let message = provider == "Grok" ? (number(error["code"]) == -32601 ? "Update Grok Build to connect subscription limits." : "Grok couldn’t return usage. Check your connection and run grok login in Terminal if sign-in has expired.") : provider == "Claude" ? "Claude couldn’t return usage. Update Claude Code and check your subscription sign-in." : "Codex couldn’t return usage. Check that you’re signed in with a subscription."
                    throw ConnectionError.unavailable(message)
                }
                return response["result"] as? [String: Any] ?? [:]
            }
            if signal.wait(timeout: deadline) == .timedOut { throw ConnectionError.unavailable("\(provider) took too long to respond. Try refreshing.") }
        }
    }
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

public enum ClaudeConnector {
    public static var directory: URL {
        ProcessInfo.processInfo.environment["LIMITTER_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Limitter")
    }
    public static var settingsURL: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("settings.json")
    }
    public static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String else { return false }
        return command.contains("limitter-bridge") && command.contains("--capture-claude")
    }
    public static var updateSignature: String {
        let paths = [settingsURL, directory.appendingPathComponent("claude-usage.json"), directory.appendingPathComponent("limitter-bridge")]
        return paths.map { url in
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(attrs?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(attrs?.fileSize ?? 0)"
        }.joined(separator: ":")
    }
    public static func read() -> ProviderLimits {
        var empty = ProviderLimits(provider: .claude, source: "Claude status line")
        guard isInstalled else { empty.error = "Connect Claude Code to receive subscription limits."; return empty }
        guard FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("limitter-bridge").path) else {
            empty.error = "Claude’s connector executable is missing. Repair the connection in Settings."; return empty
        }
        let path = directory.appendingPathComponent("claude-usage.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return empty }
        guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = ClaudeQuotaCache.timestamp(value["captured_at"]) ?? ClaudeQuotaCache.timestamp(value["received_at"]) else {
            empty.error = "Couldn’t read Claude’s quota update. Repair the connection in Settings."; return empty
        }
        return LimitsParser.claude(value, updatedAt: Date(timeIntervalSince1970: timestamp))
    }
    public static func upgradeIfNeeded(executable: URL) throws {
        let revision = directory.appendingPathComponent("bridge-revision")
        if isInstalled, (try? String(contentsOf: revision, encoding: .utf8)) != "4" { try install(executable: executable) }
    }
    public static func install(executable: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.unavailable("Claude settings are not a JSON object.") }
            settings = existing
            // Keep a complete, timestamped recovery copy before changing any settings.
            let backup = directory.appendingPathComponent("claude-settings-backup-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: backup, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        if !isInstalled {
            let previous = settings["statusLine"] as? [String: Any] ?? [:]
            try JSONSerialization.data(withJSONObject: previous).write(to: directory.appendingPathComponent("claude-previous-statusline.json"), options: .atomic)
        }
        let bridge = directory.appendingPathComponent("limitter-bridge")
        try Data(contentsOf: executable).write(to: bridge, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        var line = settings["statusLine"] as? [String: Any] ?? [:]
        line["type"] = "command"; line["command"] = shellQuote(bridge.path) + " --capture-claude"
        if line["refreshInterval"] == nil { line["refreshInterval"] = 30 }
        settings["statusLine"] = line
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        try "4".write(to: directory.appendingPathComponent("bridge-revision"), atomically: true, encoding: .utf8)
    }
    public static func uninstall() throws {
        guard isInstalled else { return }
        let data = try Data(contentsOf: settingsURL)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let previousData = try Data(contentsOf: directory.appendingPathComponent("claude-previous-statusline.json"))
        let previous = try JSONSerialization.jsonObject(with: previousData) as? [String: Any] ?? [:]
        settings["statusLine"] = previous.isEmpty ? nil : previous
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
    }
    public static func capture() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let value = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        let minimal = saveQuota(value)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("claude-previous-statusline.json")),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let command = previous["command"] as? String, !command.isEmpty, !command.contains("--capture-claude") {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
            process.standardInput = pipe; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
            do {
                try process.run(); try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch { print("Limitter connected") }
        } else {
            let limits = LimitsParser.claude(minimal, updatedAt: Date())
            let text = QuotaPeriod.allCases.compactMap { period -> String? in
                let view = QuotaPresentation(provider: .claude, snapshot: limits, period: period)
                guard view.hasValue, let window = view.window else { return nil }
                return window.title + " " + (view.state == .cached ? "~" : "") + "\(Format.percent(window.usedPercent))%"
            }.joined(separator: " · ")
            print(text.isEmpty ? "Limitter connected" : text)
        }
    }
    private static func saveQuota(_ value: [String: Any]) -> [String: Any] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("quota.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return [:] }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return [:] }
        defer { flock(descriptor, LOCK_UN) }
        let file = directory.appendingPathComponent("claude-usage.json")
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let merged = ClaudeQuotaCache.merge(value, previous: previous)
        if let data = try? JSONSerialization.data(withJSONObject: merged) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return merged
    }
    private static func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public enum ClaudeQuotaCache {
    public static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
    public static func timestamp(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }
    /// Independent windows keep independent observation times. Empty/startup events cannot refresh or erase a known quota.
    public static func merge(_ incoming: [String: Any], previous: [String: Any], now: Date = Date()) -> [String: Any] {
        var windows: [String: Any] = [:], observed: [String: Double] = [:]
        var errors = previous["window_errors"] as? [String: String] ?? [:]
        let old = previous["rate_limits"] as? [String: Any] ?? [:]
        let oldTimes = previous["window_captured_at"] as? [String: Any] ?? [:]
        let fresh = incoming["rate_limits"] as? [String: Any] ?? [:]
        for (key, label) in [("five_hour", "Session"), ("seven_day", "Weekly")] {
            if let window = old[key] as? [String: Any], let used = percentage(window["used_percentage"]),
               let time = timestamp(oldTimes[key]) ?? timestamp(previous["captured_at"]) {
                var retained: [String: Any] = ["used_percentage": used]
                retained["resets_at"] = timestamp(window["resets_at"])
                windows[key] = retained; observed[key] = time
            }
            guard let raw = fresh[key] else { continue }
            if raw is NSNull { errors[label] = nil; continue }
            if let window = raw as? [String: Any], window["used_percentage"] == nil || window["used_percentage"] is NSNull {
                errors[label] = nil
                continue
            }
            guard let window = raw as? [String: Any], let used = percentage(window["used_percentage"]) else {
                let rawPercent = (raw as? [String: Any])?["used_percentage"]
                let detail = (rawPercent as? NSNumber).map { " (received \($0))" } ?? " (missing or nonnumeric)"
                errors[label] = "Claude’s \(label.lowercased()) percentage is unreadable" + detail + ". Waiting for a valid update."
                continue
            }
            // A numeric quota can arrive before its reset timestamp is available.
            // Keep the real percentage and display 'Reset unavailable'; never invent a countdown.
            var clean: [String: Any] = ["used_percentage": used]
            clean["resets_at"] = timestamp(window["resets_at"])
            windows[key] = clean; observed[key] = now.timeIntervalSince1970
            errors[label] = nil
        }
        return ["rate_limits": windows, "window_captured_at": observed, "captured_at": observed.values.max() ?? now.timeIntervalSince1970,
                "received_at": now.timeIntervalSince1970, "window_errors": errors]
    }
}
