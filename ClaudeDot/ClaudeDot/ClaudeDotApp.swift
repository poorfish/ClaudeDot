import SwiftUI
import AppKit

@main
struct ClaudeDotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Claude Code Status

enum ClaudeStatus: Equatable {
    case disconnected
    case idle
    case thinking
    case responding
    case toolActive
    case awaitingPermission

    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .idle: return "等待输入"
        case .thinking: return "思考中"
        case .responding: return "生成回复"
        case .toolActive: return "执行工具"
        case .awaitingPermission: return "等待授权"
        }
    }

    var color: NSColor {
        switch self {
        case .disconnected:
            return NSColor(red: 120/255, green: 120/255, blue: 125/255, alpha: 1)
        case .idle:
            return NSColor(red: 80/255, green: 180/255, blue: 80/255, alpha: 1)
        case .thinking:
            return NSColor(red: 167/255, green: 139/255, blue: 250/255, alpha: 1)
        case .responding:
            return NSColor(red: 96/255, green: 165/255, blue: 250/255, alpha: 1)
        case .toolActive:
            return NSColor(red: 215/255, green: 119/255, blue: 87/255, alpha: 1)
        case .awaitingPermission:
            return NSColor(red: 251/255, green: 191/255, blue: 36/255, alpha: 1)
        }
    }
}

// MARK: - Session Info

struct SessionInfo {
    let pid: Int
    let sessionId: String
    let cwd: String
}

// MARK: - Transcript Monitor (JSONL tail)

class TranscriptMonitor {
    private var currentPath: String?
    private var fileHandle: FileHandle?
    private var fileOffset: UInt64 = 0
    private var pendingToolIds: Set<String> = []
    private(set) var lastEventType: String = ""
    private(set) var lastEventTime: Date = .distantPast
    private var buffer: String = ""

    /// Switch to monitoring a new transcript file
    func setTranscriptPath(_ path: String?) {
        guard path != currentPath else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        currentPath = path
        pendingToolIds.removeAll()
        lastEventType = ""
        lastEventTime = .distantPast
        buffer = ""
        fileOffset = 0

        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        // Seek to near end — only parse last 4KB to catch recent state
        fileHandle = FileHandle(forReadingAtPath: path)
        if let fh = fileHandle {
            let fileSize = fh.seekToEndOfFile()
            let startPos = fileSize > 4096 ? fileSize - 4096 : 0
            fh.seek(toFileOffset: startPos)
            // Read the tail to establish current state
            let data = fh.readDataToEndOfFile()
            fileOffset = fh.offsetInFile
            if let text = String(data: data, encoding: .utf8) {
                // If we seeked into the middle, skip the first partial line
                let lines = text.components(separatedBy: "\n")
                let startIdx = startPos > 0 ? 1 : 0
                for i in startIdx..<lines.count {
                    parseLine(lines[i])
                }
            }
        }
    }

    /// Read new lines appended since last check
    func poll() {
        guard let fh = fileHandle else { return }
        fh.seek(toFileOffset: fileOffset)
        let data = fh.readDataToEndOfFile()
        fileOffset = fh.offsetInFile
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        buffer += text
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""
        let timestamp = json["timestamp"] as? String

        if let timestamp, let date = parseISO8601(timestamp) {
            lastEventTime = date
        }

        let message = json["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []

        for item in content {
            let contentType = item["type"] as? String ?? ""

            switch contentType {
            case "thinking":
                lastEventType = "thinking"
            case "text" where type == "assistant":
                lastEventType = "text"
            case "tool_use":
                if let toolId = item["id"] as? String {
                    pendingToolIds.insert(toolId)
                }
                lastEventType = "tool_use"
            case "tool_result":
                if let toolId = item["tool_use_id"] as? String {
                    pendingToolIds.remove(toolId)
                }
                lastEventType = "tool_result"
            default:
                break
            }
        }

        // user type with tool_result content
        if type == "user" && !content.isEmpty {
            let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
            if hasToolResult {
                for item in content {
                    if let toolId = item["tool_use_id"] as? String {
                        pendingToolIds.remove(toolId)
                    }
                }
                lastEventType = "tool_result"
            } else {
                // User sent a new message
                lastEventType = "user_message"
            }
        }
    }

    var hasActiveTool: Bool { !pendingToolIds.isEmpty }

    var secondsSinceLastEvent: TimeInterval {
        Date().timeIntervalSince(lastEventTime)
    }

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    func reset() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentPath = nil
        pendingToolIds.removeAll()
        lastEventType = ""
        lastEventTime = .distantPast
        buffer = ""
        fileOffset = 0
    }
}

// MARK: - Claude Status Monitor (statusLine-based)

class ClaudeStatusMonitor: @unchecked Sendable {
    private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")
    private let statusFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-status.json").path

    private let stalenessThreshold: TimeInterval = 5.0
    let transcriptMonitor = TranscriptMonitor()

    /// Verify that a PID actually belongs to a Claude Code (node) process
    private func isClaudeProcess(_ pid: Int) -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let comm = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return comm.contains("node") || comm.contains("claude")
        } catch {
            return false
        }
    }

    /// Read transcript_path from statusLine JSON
    private func readTranscriptPath() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["transcript_path"] as? String
        else { return nil }
        return path
    }

    /// Read session_id from the status file
    private func statusFileSessionId() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = json["session_id"] as? String
        else { return nil }
        return sid
    }

    /// Check if statusLine file is fresh (being refreshed by idle Claude)
    private func isStatusLineFresh() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: statusFilePath),
              let attrs = try? fm.attributesOfItem(atPath: statusFilePath),
              let modDate = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modDate) < stalenessThreshold
    }

    /// Find active Claude Code sessions from ~/.claude/sessions/
    func findActiveSessions() -> [SessionInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String
            else { continue }

            if kill(Int32(pid), 0) == 0 && isClaudeProcess(pid) {
                sessions.append(SessionInfo(pid: pid, sessionId: sessionId, cwd: cwd))
            }
        }
        return sessions
    }

    /// Main detection: combines process, transcript, statusLine, and notification signals
    func detectStatus() -> (status: ClaudeStatus, session: SessionInfo?) {
        let sessions = findActiveSessions()
        guard let session = sessions.first else {
            transcriptMonitor.reset()
            cleanupStatusFile()
            NotificationHookSetup.clearMarker()
            return (.disconnected, nil)
        }

        // Ensure transcript monitor is tracking the right file
        if let path = readTranscriptPath() {
            transcriptMonitor.setTranscriptPath(path)
        }

        // Poll for new transcript events
        transcriptMonitor.poll()

        // Priority 1: Check notification hook for permission prompt
        if NotificationHookSetup.hasActiveNotification() {
            return (.awaitingPermission, session)
        }

        // Priority 2: Heuristic permission detection
        // tool_use pending + no transcript activity for 3s + statusLine not refreshing
        if transcriptMonitor.hasActiveTool
            && transcriptMonitor.secondsSinceLastEvent > 3.0
            && !isStatusLineFresh() {
            return (.awaitingPermission, session)
        }

        // Priority 3: Active tool execution
        if transcriptMonitor.hasActiveTool {
            return (.toolActive, session)
        }

        // Priority 4: Recent transcript activity determines thinking/responding
        let recency = transcriptMonitor.secondsSinceLastEvent
        if recency < 10.0 {
            switch transcriptMonitor.lastEventType {
            case "thinking":
                return (.thinking, session)
            case "text":
                return (.responding, session)
            case "tool_result":
                // Just finished a tool, likely about to think or respond
                return (.thinking, session)
            case "tool_use":
                return (.toolActive, session)
            case "user_message":
                // User just sent message, Claude about to think
                return (.thinking, session)
            default:
                break
            }
        }

        // Priority 5: statusLine freshness → idle
        if isStatusLineFresh() {
            return (.idle, session)
        }

        // Priority 6: statusLine stale but no transcript activity → likely busy (API call)
        if recency > 10.0 && !isStatusLineFresh() {
            return (.thinking, session)
        }

        return (.idle, session)
    }

    func cleanupStatusFile() {
        try? FileManager.default.removeItem(atPath: statusFilePath)
    }
}

// MARK: - Notification Hook Setup

class NotificationHookSetup {
    private static let scriptPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-notify.sh").path
    static let markerPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-notification.json").path

    static func ensureConfigured() {
        let fm = FileManager.default

        // 1. Create notification script
        let script = """
        #!/bin/bash
        MARKER="$HOME/.claude/claudedot-notification.json"
        INPUT=$(cat)
        if [ -n "$INPUT" ]; then
            echo "$INPUT" > "${MARKER}.tmp" && mv "${MARKER}.tmp" "$MARKER"
        fi
        """
        if !fm.fileExists(atPath: scriptPath) {
            do {
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            } catch {
                print("[ClaudeDot] Failed to create notification script: \(error)")
            }
        }

        // 2. Add Notification hook to settings.json
        let settingsPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        guard fm.fileExists(atPath: settingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        if hooks["Notification"] == nil {
            hooks["Notification"] = [[
                "matcher": "",
                "commands": [scriptPath]
            ]]
            settings["hooks"] = hooks
            do {
                let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try newData.write(to: URL(fileURLWithPath: settingsPath))
                print("[ClaudeDot] Added Notification hook to settings.json")
            } catch {
                print("[ClaudeDot] Failed to update settings.json: \(error)")
            }
        }
    }

    /// Check if a notification marker exists and is fresh (< 30s)
    static func hasActiveNotification() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: markerPath),
              let attrs = try? fm.attributesOfItem(atPath: markerPath),
              let modDate = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modDate) < 30.0
    }

    /// Clear notification marker (called when status changes away from awaiting)
    static func clearMarker() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }
}

// MARK: - StatusLine Auto-Setup

class StatusLineSetup {
    private static let scriptPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-statusline.sh").path

    /// Ensure statusLine script and settings.json are configured
    static func ensureConfigured() -> Bool {
        let fm = FileManager.default

        // 1. Create script if missing
        if !fm.fileExists(atPath: scriptPath) {
            let script = """
            #!/bin/bash
            STATUS_FILE="$HOME/.claude/claudedot-status.json"
            INPUT=$(cat)
            if [ -n "$INPUT" ]; then
                echo "$INPUT" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            fi
            """
            do {
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            } catch {
                print("[ClaudeDot] Failed to create statusLine script: \(error)")
                return false
            }
        }

        // 2. Ensure settings.json has statusLine configured
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        guard fm.fileExists(atPath: settingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        if settings["statusLine"] == nil {
            settings["statusLine"] = [
                "type": "command",
                "command": "~/.claude/claudedot-statusline.sh",
                "refreshInterval": 3
            ] as [String: Any]

            do {
                let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try newData.write(to: URL(fileURLWithPath: settingsPath))
                print("[ClaudeDot] Added statusLine to settings.json")
            } catch {
                print("[ClaudeDot] Failed to update settings.json: \(error)")
                return false
            }
        }

        return true
    }
}

// MARK: - Sound Manager

class SoundManager {
    static let shared = SoundManager()
    var enabled = true
    private var previousStatus: ClaudeStatus = .disconnected

    func playStatusChange(from oldStatus: ClaudeStatus, to newStatus: ClaudeStatus) {
        guard enabled else { return }
        switch newStatus {
        case .disconnected:
            NSSound(named: "Basso")?.play()
        case .idle:
            // Only play "Pop" when transitioning from a working state
            if [.thinking, .responding, .toolActive, .awaitingPermission].contains(oldStatus) {
                NSSound(named: "Pop")?.play()
            }
        case .thinking, .responding:
            // Silent — these toggle too frequently
            break
        case .toolActive:
            NSSound(named: "Tink")?.play()
        case .awaitingPermission:
            NSSound(named: "Submarine")?.play()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var animationTimer: Timer?
    private var monitorTimer: Timer?
    private var pulsePhase: CGFloat = 0
    private(set) var currentStatus: ClaudeStatus = .disconnected
    private(set) var currentSession: SessionInfo?
    private let monitor = ClaudeStatusMonitor()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var needsRestart = false

    private let dotSize: CGFloat = 10

    func colorForStatus(_ status: ClaudeStatus) -> NSColor {
        status.color
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto-setup statusLine hook and notification hook
        needsRestart = StatusLineSetup.ensureConfigured()
        NotificationHookSetup.ensureConfigured()

        setupStatusItem()
        setupPopover()
        startAnimationLoop()
        startMonitoring()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = createDotImage(alpha: 0.3)
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 300, height: 280)
        popover.behavior = .semitransient
        updatePopoverContent()
    }

    private func updatePopoverContent() {
        popover.contentViewController = NSHostingController(
            rootView: SettingsView(appDelegate: self)
        )
    }

    // MARK: - Dot Rendering

    private func createDotImage(alpha: CGFloat) -> NSImage {
        let color = colorForStatus(currentStatus)
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(
                x: (rect.width - self.dotSize) / 2,
                y: (rect.height - self.dotSize) / 2,
                width: self.dotSize,
                height: self.dotSize
            )
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Animation

    private func startAnimationLoop() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.pulsePhase += 1.0 / 30

            let alpha: CGFloat
            switch self.currentStatus {
            case .disconnected:
                // Static, dim
                alpha = 0.3
            case .idle:
                // Gentle breathing, 1.5s cycle
                let t = self.pulsePhase * (2 * .pi) / 3.0 // 3s full cycle = 1.5s half
                alpha = 0.65 + 0.2 * CGFloat(sin(t))
            case .thinking:
                // Soft pulse, 2s cycle
                let t = self.pulsePhase * (2 * .pi) / 2.0
                alpha = 0.5 + 0.4 * CGFloat(sin(t) * 0.5 + 0.5)
            case .responding:
                // Medium pulse, 1.5s cycle
                let t = self.pulsePhase * (2 * .pi) / 1.5
                alpha = 0.45 + 0.5 * CGFloat(sin(t) * 0.5 + 0.5)
            case .toolActive:
                // Fast pulse, 1s cycle
                let t = self.pulsePhase * (2 * .pi) / 1.0
                alpha = 0.4 + 0.6 * CGFloat(sin(t) * 0.5 + 0.5)
            case .awaitingPermission:
                // Blink on/off, 0.8s cycle
                let t = self.pulsePhase.truncatingRemainder(dividingBy: 0.8)
                alpha = t < 0.4 ? 0.95 : 0.2
            }
            button.image = self.createDotImage(alpha: alpha)
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkClaudeStatus()
        }
        checkClaudeStatus()
    }

    private func checkClaudeStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.monitor.detectStatus()
            DispatchQueue.main.async {
                self.currentSession = result.session
                let newStatus = result.status
                if newStatus != self.currentStatus {
                    let oldStatus = self.currentStatus
                    self.currentStatus = newStatus
                    self.pulsePhase = 0
                    SoundManager.shared.playStatusChange(from: oldStatus, to: newStatus)
                    self.updatePopoverContent()
                    // Clear notification marker when leaving awaitingPermission
                    if oldStatus == .awaitingPermission && newStatus != .awaitingPermission {
                        NotificationHookSetup.clearMarker()
                    }
                }
            }
        }
    }

    // MARK: - Click

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            togglePopover(sender)
        } else {
            activateClaudeCode()
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            updatePopoverContent()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            addClickMonitors()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeClickMonitors()
    }

    private func addClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopover()
            return event
        }
    }

    private func removeClickMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    private func activateClaudeCode() {
        let terminals = [
            "com.mitchellh.ghostty",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.apple.Terminal"
        ]
        for bundleId in terminals {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate()
                return
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Public

    var soundEnabled: Bool {
        get { SoundManager.shared.enabled }
        set { SoundManager.shared.enabled = newValue }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let appDelegate: AppDelegate
    @State private var soundEnabled: Bool
    @State private var selectedTerminal = "auto"

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        _soundEnabled = State(initialValue: appDelegate.soundEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Circle()
                    .fill(Color(nsColor: appDelegate.colorForStatus(appDelegate.currentStatus)))
                    .frame(width: 10, height: 10)
                Text("Claude Dot")
                    .font(.headline)
                Spacer()
                Text("v1.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Status info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("状态")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(nsColor: appDelegate.colorForStatus(appDelegate.currentStatus)))
                            .frame(width: 6, height: 6)
                        Text(appDelegate.currentStatus.label)
                            .font(.subheadline)
                    }
                }

                if let session = appDelegate.currentSession {
                    HStack {
                        Text("PID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(session.pid)")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("工作目录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(shortenPath(session.cwd))
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider()

            // Settings
            Toggle("音效提示", isOn: $soundEnabled)
                .font(.body)
                .onChange(of: soundEnabled) { _, newValue in
                    appDelegate.soundEnabled = newValue
                }

            Picker("终端应用", selection: $selectedTerminal) {
                Text("自动检测").tag("auto")
                Text("Terminal").tag("terminal")
                Text("iTerm2").tag("iterm")
                Text("Warp").tag("warp")
                Text("Ghostty").tag("ghostty")
            }
            .font(.body)

            Divider()

            HStack {
                Spacer()
                Button("退出 Claude Dot") {
                    NSApp.terminate(nil)
                }
                .font(.body)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
