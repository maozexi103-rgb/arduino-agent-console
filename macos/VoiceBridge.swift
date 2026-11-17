import AppKit
import ApplicationServices
import Darwin

// User-requested hardware integration: no audio, transcript, clipboard or submit.
// B1 toggles native dictation, B2 opens a new chat, B3 presses ONLY a specifically
// labelled dictation-cancel button or invokes Codex's dedicated composer.clear.
// B3 reads control roles/names/children in the focused window, never field values.
// B4 activates the known Codex app and sends its native Voice Chat toggle.
final class PressGate {
    var lastCount = 0
    var lastTime = -Double.infinity
    func accept(count: Int, now: Double) -> Bool {
        guard count > lastCount else { return false }
        lastCount = count
        guard now - lastTime >= 0.5 else { return false }
        lastTime = now
        return true
    }
}

struct ButtonPress {
    let button: Int
    let count: Int
    static func parse(_ line: String) -> ButtonPress? {
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "EVENT", parts[2] == "DOWN",
              parts[1].hasPrefix("B"), let button = Int(parts[1].dropFirst()),
              (1...4).contains(button), parts[3].hasPrefix("count="),
              let count = Int(parts[3].dropFirst(6)), count > 0 else { return nil }
        return ButtonPress(button: button, count: count)
    }
}

func newChatURL(workspace: String) -> URL {
    var components = URLComponents()
    components.scheme = "codex"
    components.host = "threads"
    components.path = "/new"
    components.queryItems = [URLQueryItem(name: "path", value: workspace)]
    return components.url!
}

let dictationCancelLabels: Set<String> = [
    "取消听写", "取消转录", "取消聽寫", "取消轉錄",
    "Cancel dictation", "Cancel transcription"
].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

func isDictationCancelLabel(_ label: String) -> Bool {
    dictationCancelLabels.contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

func isClearPromptAccelerator(_ accelerator: String) -> Bool {
    let aliases = ["control": "ctrl", "option": "alt"]
    let parts = accelerator.lowercased().split(separator: "+").map {
        let key = $0.trimmingCharacters(in: .whitespaces)
        return aliases[key] ?? key
    }
    return parts.count == 4 && Set(parts) == Set(["ctrl", "alt", "shift", "backspace"])
}

enum CancelControlSearch {
    case found(AXUIElement)
    case none
    case unavailable
}

struct AXScanMetrics {
    var nodes = 0
    var buttons = 0
    var manualAccessibilityResult: Int32 = 0
}

func axAttribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func findDictationCancelControl(pid: pid_t, metrics: inout AXScanMetrics) -> CancelControlSearch {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    // Electron exposes its web controls only after accessibility support is active.
    // This uses the existing user-granted AX permission, not a permission bypass.
    metrics.manualAccessibilityResult = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
    guard let value = axAttribute(app, kAXFocusedWindowAttribute as CFString),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
    let window = unsafeBitCast(value, to: AXUIElement.self)
    var queue = [window]
    var index = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 2.5
    while index < queue.count {
        guard index < 4000, ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
        let element = queue[index]; index += 1
        metrics.nodes = index
        let role = axAttribute(element, kAXRoleAttribute as CFString) as? String
        if role == (kAXButtonRole as String) { metrics.buttons += 1 }
        if role == (kAXButtonRole as String) {
            let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { axAttribute(element, $0 as CFString) as? String }
            if names.contains(where: isDictationCancelLabel),
               (axAttribute(element, kAXEnabledAttribute as CFString) as? Bool) == true {
                // An optional action list must not exclude this verified target;
                // the caller validates its live location before clicking.
                return .found(element)
            }
        }
        // AXVisibleChildren can omit dynamically replaced composer controls.
        // Walk actual child links, keeping the same node/time budget and no values.
        let children = axAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        queue.append(contentsOf: children)
    }
    return .none
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute as CFString),
          let s = axAttribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func cancelButtonCenter(_ frame: CGRect, inside window: CGRect) -> CGPoint? {
    guard [frame.minX, frame.minY, frame.width, frame.height,
           window.minX, window.minY, window.width, window.height].allSatisfy({ $0.isFinite }),
          frame.width >= 4, frame.height >= 4, frame.width <= 400, frame.height <= 200,
          window.width > 0, window.height > 0, window.contains(frame) else { return nil }
    return CGPoint(x: frame.midX, y: frame.midY)
}

struct AgentSnapshot: Decodable {
    let schemaVersion: Int
    let source: String
    let threadId: String
    let turnId: String
    let state: String
    let waitKind: String?
    let updatedAt: Double
    let revision: Int

    static func parse(_ data: Data) -> AgentSnapshot? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard data.count <= 65536, let value = try? decoder.decode(AgentSnapshot.self, from: data),
              value.schemaVersion == 1, value.source == "codex-hook", !value.threadId.isEmpty,
              !value.turnId.isEmpty, value.updatedAt.isFinite, value.updatedAt > 0,
              ["RUNNING", "WAITING", "DONE", "IDLE"].contains(value.state) else { return nil }
        return value
    }
}

func agentLEDMode(bridgeMode: String, state: String?, codexRunning: Bool) -> String {
    if bridgeMode == "ERROR" { return "ERROR" }
    guard codexRunning else { return "OFFLINE" }
    // Preserve the proven firmware protocol. These are electrical color codes:
    // RECORDING = yellow, ERROR = red, READY = green, OFFLINE = red short pulse.
    switch state {
    case "RUNNING": return "RECORDING"
    case "WAITING": return "ERROR"
    case "DONE", "IDLE": return "READY"
    default: return "OFFLINE"
    }
}


// Local configuration stays outside the repository. Missing keys use defaults.
struct BridgeConfig: Decodable {
    var workspacePath: String?
    var codexAppPath: String?
    var serialPort: String?
    enum CodingKeys: String, CodingKey {
        case workspacePath = "workspace_path", codexAppPath = "codex_app_path", serialPort = "serial_port"
    }
    static func parse(_ data: Data) throws -> BridgeConfig {
        let value = try JSONDecoder().decode(BridgeConfig.self, from: data)
        for path in [value.workspacePath, value.codexAppPath].compactMap({ $0 }) {
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else {
                throw NSError(domain: "BridgeConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use absolute local paths"])
            }
        }
        if let port = value.serialPort {
            guard port.hasPrefix("/dev/cu."), !port.dropFirst(5).contains("/"),
                  !port.contains("\n"), !port.contains("\0") else {
                throw NSError(domain: "BridgeConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "serial_port must be a /dev/cu.* device"])
            }
        }
        return value
    }
    static func load() throws -> BridgeConfig {
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ArduinoVoiceBridge/config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return BridgeConfig() }
        return try parse(Data(contentsOf: file))
    }
    var workspace: String {
        workspacePath ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
    }
    var codexURL: URL? {
        let url = codexAppPath.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        guard let url = url, Bundle(url: url)?.bundleIdentifier == "com.openai.codex" else { return nil }
        return url.standardizedFileURL
    }
}

final class VoiceBridge: NSObject, NSApplicationDelegate {
    var config = BridgeConfig()
    var item: NSStatusItem!
    var statusRow = NSMenuItem(title: "正在连接Arduino", action: nil, keyEquivalent: "")
    var permissionRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var agentRow = NSMenuItem(title: "Agent状态：等待首次真实任务事件", action: nil, keyEquivalent: "")
    var agentSnapshot: AgentSnapshot?
    var bridgeMode = "READY"
    var agentSignature = ""
    let agentStateURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ArduinoVoiceBridge/agent-state.json")
    var descriptor: Int32 = -1
    var reader: DispatchSourceRead?
    var timer: Timer?
    var buffer = Data()
    var ready = false
    var sawStartup = false
    var recordingRequested = false
    var desynced = false
    var gates = (0..<4).map { _ in PressGate() }
    var newChatPending = false
    var cancelPending = false
    var dotTogglePending = false
    var requestID = 0
    var lastPing = 0.0
    var lastLine = 0.0
    var lastReportedMode = ""
    var text = "正在连接Arduino"
    let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/ArduinoVoiceBridge/events.jsonl")

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data + Data([10])); try? h.close()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "hk.edu.int4089.ArduinoVoiceBridge").count > 1 {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙 UNO"
        let menu = NSMenu()
        statusRow.isEnabled = false; permissionRow.isEnabled = false; agentRow.isEnabled = false
        menu.addItem(statusRow); menu.addItem(agentRow); menu.addItem(permissionRow); menu.addItem(.separator())
        let help = NSMenuItem(title: "打开辅助功能设置", action: #selector(openPermissions), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        let reset = NSMenuItem(title: "先手动结束录音，再点此重置", action: #selector(resetState), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出Arduino语音桥", action: #selector(quit), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        log("APP_START", ["version": "0.5.1", "B1": "Cmd+Shift+D", "B2": "codex://threads/new?path=...", "B3": "dictation-cancel-or-composer.clear", "B4": "Ctrl+Shift+V", "target": "com.openai.codex", "LED_source": "codex-lifecycle-hooks"])
        do { config = try BridgeConfig.load() }
        catch {
            statusRow.title = "配置文件无效，请检查config.json后重启"
            log("CONFIG_INVALID")
            return
        }
        // macOS presents its standard onboarding prompt; the user grants access.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    @objc func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func resetState() {
        recordingRequested = false; desynced = false
        update("已重置；请在Codex输入框按第一键", mode: "READY")
        log("USER_RESET")
    }
    @objc func quit() {
        if recordingRequested {
            let alert = NSAlert()
            alert.messageText = "请先在Codex中结束录音"
            alert.informativeText = "退出桥接不会自动停止Codex录音。请先按⌘⇧D结束，再退出。"
            alert.addButton(withTitle: "返回")
            alert.runModal(); return
        }
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        write("SET OFFLINE \(requestID + 1)\n")
        disconnect()
        log("APP_STOP")
    }

    func update(_ message: String, mode: String) {
        text = message; statusRow.title = message
        bridgeMode = mode
        item.button?.title = recordingRequested ? "🔴 UNO" : (mode == "ERROR" ? "⚠️ UNO" : "🎙 UNO")
        refreshAgentState()
        renderLED()
    }
    func refreshAgentState() {
        let size = (try? agentStateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        agentSnapshot = size > 0 && size <= 65536
            ? (try? Data(contentsOf: agentStateURL)).flatMap(AgentSnapshot.parse) : nil
        let value = agentSnapshot
        let signature = value.map { "\($0.threadId):\($0.turnId):\($0.state):\($0.waitKind ?? "")" } ?? "UNAVAILABLE"
        if signature != agentSignature {
            agentSignature = signature
            if let value = value {
                log("AGENT_STATE_OBSERVED", ["thread_id": value.threadId, "turn_id": value.turnId,
                                            "state": value.state, "wait_kind": value.waitKind ?? "", "revision": value.revision])
            } else { log("AGENT_STATE_UNAVAILABLE") }
        }
        switch value?.state {
        case "RUNNING": agentRow.title = "Agent状态：正在工作（黄灯）"
        case "WAITING": agentRow.title = value?.waitKind == "permission" ? "Agent状态：等待权限（红灯）" : "Agent状态：等待回答／选择（红灯）"
        case "DONE": agentRow.title = "Agent状态：本轮结束，待你检查（绿灯）"
        case "IDLE": agentRow.title = "Agent状态：当前空闲／已中断（绿灯）"
        default: agentRow.title = "Agent状态：等待真实事件／请检查hooks信任（红灯慢闪）"
        }
    }
    func renderLED() {
        let codexRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
        let mode = agentLEDMode(bridgeMode: bridgeMode, state: agentSnapshot?.state, codexRunning: codexRunning)
        if ready && mode != lastReportedMode {
            requestID += 1; write("SET \(mode) \(requestID)\n")
            lastReportedMode = mode
            log("LED_STATE_REQUESTED", ["mode": mode, "agent_state": agentSnapshot?.state ?? "UNKNOWN", "bridge_mode": bridgeMode])
        }
    }
    func tick() {
        permissionRow.title = AXIsProcessTrusted() ? "辅助功能：已授权" : "辅助功能：未授权，请在系统设置开启"
        refreshAgentState()
        if descriptor < 0 { connect(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLine > 6 {
            log("SERIAL_TIMEOUT"); lostConnection(); return
        }
        if now - lastPing >= 2 { lastPing = now; write("PING\n") }
        if ready && !AXIsProcessTrusted() {
            update("等待辅助功能授权", mode: "ERROR")
        } else if ready && !desynced && !recordingRequested && bridgeMode == "ERROR" {
            update("就绪：在Codex输入框按第一键", mode: "READY")
        }
        renderLED()
    }

    func connect() {
        let ports: [String]
        if let port = config.serialPort {
            ports = FileManager.default.fileExists(atPath: port) ? [String(port.dropFirst(5))] : []
        } else {
            ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
                .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") }.sorted()
        }
        guard ports.count == 1 else {
            statusRow.title = ports.isEmpty ? "未发现Arduino USB，请检查连接" : "发现多个USB串口；请只连接这一块UNO"
            return
        }
        let path = "/dev/" + ports[0]
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { statusRow.title = "无法打开Arduino串口"; return }
        // Respect another uploader/monitor instead of sharing the serial stream.
        guard ioctl(fd, TIOCEXCL) == 0 else { Darwin.close(fd); statusRow.title = "串口被占用，请关闭测试监听"; return }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { Darwin.close(fd); return }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetispeed(&settings, speed_t(B115200)); cfsetospeed(&settings, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else { Darwin.close(fd); return }
        tcflush(fd, TCIOFLUSH)
        descriptor = fd; ready = false; sawStartup = false; buffer.removeAll()
        lastLine = ProcessInfo.processInfo.systemUptime; lastPing = 0
        lastReportedMode = ""
        gates = (0..<4).map { _ in PressGate() }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader = source
        source.setEventHandler { [weak self] in self?.readSerial() }
        source.resume()
        log("SERIAL_OPEN", ["port": path]); statusRow.title = "正在等待Arduino握手"
    }
    func disconnect() {
        reader?.cancel(); reader = nil
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1; ready = false; buffer.removeAll()
    }
    func lostConnection() {
        if recordingRequested { desynced = true }
        disconnect()
        update(desynced ? "连接中断；请手动结束录音后重置" : "Arduino已断开，等待重连", mode: "ERROR")
    }
    func write(_ string: String) {
        guard descriptor >= 0 else { return }
        let bytes = Array(string.utf8)
        let n = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if n != bytes.count { log("SERIAL_WRITE_FAILED") }
    }
    func readSerial() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno != EAGAIN { lostConnection() }
            return
        }
        if n == 0 { return }
        lastLine = ProcessInfo.processInfo.systemUptime
        buffer.append(contentsOf: bytes.prefix(n))
        if buffer.count > 16384 { buffer.removeAll(); log("SERIAL_BUFFER_RESET"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            handle(line)
        }
    }
    func handle(_ line: String) {
        if line.hasPrefix("VOICE_CONSOLE READY") {
            if recordingRequested { desynced = true }
            recordingRequested = false; ready = false; sawStartup = true
            gates = (0..<4).map { _ in PressGate() }
            log("BOARD_STARTUP"); write("PING\n"); return
        }
        if line == "PONG VOICE_CONSOLE" && sawStartup {
            if !ready {
                ready = true
                log("BOARD_HANDSHAKE")
                update(desynced ? "请手动结束录音后重置" : (AXIsProcessTrusted() ? "就绪：在Codex输入框按第一键" : "等待辅助功能授权"),
                       mode: desynced || !AXIsProcessTrusted() ? "ERROR" : "READY")
            }
            return
        }
        if line.hasPrefix("ACK ") { log("BOARD_ACK", ["line": line]); return }
        guard line.hasPrefix("EVENT ") else { return }
        log("BUTTON_EVENT", ["line": line])
        guard ready, let press = ButtonPress.parse(line) else { return }
        guard !cancelPending else { log("PRESS_BLOCKED_CANCEL_PENDING", ["button": press.button]); return }
        guard !dotTogglePending else { log("PRESS_BLOCKED_DOT_PENDING", ["button": press.button]); return }
        guard gates[press.button - 1].accept(count: press.count, now: ProcessInfo.processInfo.systemUptime) else {
            log("PRESS_SUPPRESSED", ["button": press.button]); return
        }
        if press.button == 1 { toggleDictation() }
        else if press.button == 2 { openNewChat() }
        else if press.button == 3 { cancelInput() }
        else { toggleDotCall() }
    }

    func toggleDotCall() {
        guard !recordingRequested && !desynced && !newChatPending else {
            log("DOT_CALL_BLOCKED_RECORDING_OR_PENDING")
            update("先结束或取消听写，再按第四键通话", mode: "ERROR"); return
        }
        guard AXIsProcessTrusted() else {
            log("DOT_CALL_BLOCKED_PERMISSION")
            update("请先恢复辅助功能权限", mode: "ERROR"); return
        }
        guard let appURL = config.codexURL else {
            log("DOT_CALL_TARGET_MISSING"); update("未找到Codex，请检查配置", mode: "ERROR"); return
        }
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .first(where: { $0.bundleURL?.standardizedFileURL == appURL }), !target.isTerminated else {
            log("DOT_CALL_TARGET_NOT_RUNNING")
            update("请先打开本机Codex，再按第四键", mode: "ERROR"); return
        }
        dotTogglePending = true
        let pid = target.processIdentifier
        log("DOT_CALL_ACTIVATE_REQUESTED", ["pid": pid])
        _ = target.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            defer { self.dotTogglePending = false }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  AXIsProcessTrusted(), !self.recordingRequested && !self.desynced else {
                self.log("DOT_CALL_ACTIVATION_NOT_CONFIRMED")
                self.update("未确认Codex已在前台，未发送通话快捷键", mode: "ERROR"); return
            }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                self.log("DOT_CALL_KEY_EVENT_FAILED")
                self.update("创建通话快捷键失败", mode: "ERROR"); return
            }
            down.flags = [.maskControl, .maskShift]; up.flags = down.flags
            down.postToPid(pid); up.postToPid(pid)
            self.log("DOT_CALL_TOGGLE_REQUESTED", ["pid": pid, "command": "composer.startVoiceMode"])
            self.update("已请求切换Dot通话；请在Codex确认", mode: "READY")
        }
    }

    func clickVerifiedCancel(_ control: AXUIElement, pid: pid_t) -> Bool {
        var owner: pid_t = 0
        guard AXUIElementGetPid(control, &owner) == .success, owner == pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              (axAttribute(control, kAXRoleAttribute as CFString) as? String) == (kAXButtonRole as String),
              (axAttribute(control, kAXEnabledAttribute as CFString) as? Bool) == true else { return false }
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { axAttribute(control, $0 as CFString) as? String }
        let app = AXUIElementCreateApplication(pid)
        guard names.contains(where: isDictationCancelLabel),
              let windowValue = axAttribute(app, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              let windowFrame = axFrame(unsafeBitCast(windowValue, to: AXUIElement.self)),
              let frame = axFrame(control), let center = cancelButtonCenter(frame, inside: windowFrame),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    func cancelInput() {
        guard AXIsProcessTrusted() else {
            update("请先恢复辅助功能权限", mode: "ERROR"); log("B3_BLOCKED_PERMISSION"); return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.openai.codex" else {
            update("请切回Codex后再取消输入", mode: "ERROR"); log("B3_BLOCKED_TARGET"); return
        }
        guard !newChatPending else { log("B3_BLOCKED_NEW_CHAT_PENDING"); return }
        var metrics = AXScanMetrics()
        switch findDictationCancelControl(pid: front.processIdentifier, metrics: &metrics) {
        case .found(let control):
            // This app reports AXPress success without activating the control.
            // Use the verified live target instead and confirm its disappearance.
            guard clickVerifiedCancel(control, pid: front.processIdentifier) else {
                log("DICTATION_CANCEL_CLICK_BLOCKED")
                update("未能确认取消按钮位置，未执行点击", mode: "ERROR"); return
            }
            cancelPending = true
            let pid = front.processIdentifier
            log("DICTATION_CANCEL_REQUESTED", ["pid": pid, "method": "verified-button-click"])
            update("已点击取消听写，正在确认", mode: recordingRequested ? "RECORDING" : "REVIEW")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                self.cancelPending = false
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    self.desynced = true
                    self.log("DICTATION_CANCEL_UNCONFIRMED_TARGET_CHANGED")
                    self.update("取消后前台已切换，请检查并重置", mode: "ERROR"); return
                }
                var afterMetrics = AXScanMetrics()
                switch findDictationCancelControl(pid: pid, metrics: &afterMetrics) {
                case .none:
                    self.recordingRequested = false; self.desynced = false
                    self.log("DICTATION_CANCEL_CONTROL_DISAPPEARED")
                    self.update("取消控件已消失，请检查本次语音已丢弃", mode: "READY")
                case .found, .unavailable:
                    self.desynced = true
                    self.log("DICTATION_CANCEL_NOT_CONFIRMED")
                    self.update("取消尚未确认，请用鼠标检查后重置", mode: "ERROR")
                }
            }
        case .unavailable:
            log("B3_CONTROL_SEARCH_UNAVAILABLE", ["nodes": metrics.nodes, "buttons": metrics.buttons, "manual_ax_result": metrics.manualAccessibilityResult])
            update("未能确认录音控件，未清除任何内容", mode: "ERROR")
        case .none:
            guard !recordingRequested && !desynced else {
                log("B3_CANCEL_CONTROL_NOT_FOUND", ["nodes": metrics.nodes, "buttons": metrics.buttons, "manual_ax_result": metrics.manualAccessibilityResult])
                update("未找到专用取消听写按钮，请手动结束后重置", mode: "ERROR"); return
            }
            let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/keybindings.json")
            guard let data = try? Data(contentsOf: config),
                  let bindings = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  bindings.contains(where: { ($0["command"] as? String) == "composer.clear" && isClearPromptAccelerator($0["key"] as? String ?? "") }) else {
                log("B3_CLEAR_BINDING_MISSING")
                update("清空提示词专用快捷键尚未配置", mode: "ERROR"); return
            }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                log("B3_KEY_EVENT_FAILED"); return
            }
            down.flags = [.maskControl, .maskAlternate, .maskShift]
            up.flags = down.flags
            down.postToPid(front.processIdentifier); up.postToPid(front.processIdentifier)
            log("DRAFT_CLEAR_REQUESTED", ["command": "composer.clear", "pid": front.processIdentifier])
            update("已请求清空未发送提示词", mode: "READY")
        }
    }

    func openNewChat() {
        guard !recordingRequested && !desynced else {
            log("NEW_CHAT_BLOCKED_RECORDING_OR_DESYNC")
            update("先用第一键结束录音，再按第二键新建", mode: "ERROR")
            return
        }
        guard !newChatPending else { log("NEW_CHAT_SUPPRESSED_PENDING"); return }
        guard let targetURL = config.codexURL else {
            log("NEW_CHAT_TARGET_MISSING")
            update("未找到本机Codex应用", mode: "ERROR")
            return
        }
        let workspace = config.workspace
        let url = newChatURL(workspace: workspace)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        newChatPending = true
        log("NEW_CHAT_OPEN_REQUESTED", ["route": "codex://threads/new", "workspace": workspace])
        NSWorkspace.shared.open([url], withApplicationAt: targetURL, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.newChatPending = false
                if let error = error {
                    self.log("NEW_CHAT_OPEN_FAILED", ["error": error.localizedDescription])
                    self.update("打开新对话失败，请查看日志", mode: "ERROR")
                    return
                }
                self.log("NEW_CHAT_OPEN_ACCEPTED", ["pid": application?.processIdentifier ?? 0])
                self.update("已请求打开新对话；可按第一键语音输入", mode: "READY")
            }
        }
    }

    func toggleDictation() {
        guard !desynced else { log("BLOCKED_DESYNC"); return }
        guard AXIsProcessTrusted() else {
            update("请先开启辅助功能权限", mode: "ERROR"); log("BLOCKED_PERMISSION"); return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.openai.codex" else {
            update("请切回Codex并点一下输入框", mode: "ERROR"); log("BLOCKED_TARGET_NOT_FRONTMOST"); return
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 2, keyDown: false) else {
            update("快捷键事件创建失败", mode: "ERROR"); log("KEY_EVENT_FAILED"); return
        }
        down.flags = [.maskCommand, .maskShift]; up.flags = [.maskCommand, .maskShift]
        // Never sends Return, never activates a different app, never changes clipboard.
        down.postToPid(front.processIdentifier); up.postToPid(front.processIdentifier)
        recordingRequested.toggle()
        let action = recordingRequested ? "START_REQUESTED" : "STOP_REQUESTED"
        log("DICTATION_SHORTCUT", ["action": action, "pid": front.processIdentifier])
        update(recordingRequested ? "已发送开始指令；再按第一键结束" : "已发送结束指令；请检查转写后手动发送",
               mode: recordingRequested ? "RECORDING" : "REVIEW")
    }
}

if CommandLine.arguments.contains("--self-test") {
    let custom = try! BridgeConfig.parse(Data(#"{"workspace_path":"/tmp/demo project","serial_port":"/dev/cu.usbserial-demo"}"#.utf8))
    precondition(custom.workspace == "/tmp/demo project" && custom.serialPort == "/dev/cu.usbserial-demo")
    precondition((try? BridgeConfig.parse(Data(#"{"workspace_path":"relative/path"}"#.utf8))) == nil)
    precondition((try? BridgeConfig.parse(Data(#"{"serial_port":"/tmp/not-a-device"}"#.utf8))) == nil)
    precondition((try? BridgeConfig.parse(Data("not json".utf8))) == nil)
    let g = PressGate()
    precondition(g.accept(count: 1, now: 1))
    precondition(!g.accept(count: 1, now: 2), "duplicate events must not toggle")
    precondition(!g.accept(count: 2, now: 1.1), "fast accidental double press must be suppressed")
    precondition(g.accept(count: 3, now: 2), "next deliberate press must work")
    precondition(!g.accept(count: 2, now: 3), "old events must be ignored")
    let b1Gate = PressGate(), b2Gate = PressGate()
    precondition(b1Gate.accept(count: 1, now: 1))
    precondition(b2Gate.accept(count: 1, now: 1.1), "B2 must not share B1 counters or timing")
    precondition(ButtonPress.parse("EVENT B2 DOWN count=3")?.button == 2)
    precondition(ButtonPress.parse("EVENT B2 DOWN count=3")?.count == 3)
    for invalid in ["EVENT B2 UP held_ms=30", "EVENT B5 DOWN count=1", "EVENT B2 DOWN count=0", "EVENT B2 DOWN count=NaN"] {
        precondition(ButtonPress.parse(invalid) == nil)
    }
    let link = newChatURL(workspace: "/tmp/agent-console-demo/中文 project")
    let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
    precondition(components.scheme == "codex" && components.host == "threads" && components.path == "/new")
    precondition(components.queryItems?.count == 1 && components.queryItems?.first?.name == "path")
    precondition(components.queryItems?.first?.value == "/tmp/agent-console-demo/中文 project")
    let thirdGate = PressGate()
    precondition(thirdGate.accept(count: 1, now: 1.15), "B3 independent from B1/B2")
    precondition(ButtonPress.parse("EVENT B3 DOWN count=7")?.button == 3)
    let fourthGate = PressGate()
    precondition(fourthGate.accept(count: 1, now: 1.2), "B4 independent from other keys")
    precondition(!fourthGate.accept(count: 1, now: 2), "B4 duplicate must not toggle")
    precondition(fourthGate.accept(count: 2, now: 2.2), "second B4 press must work")
    precondition(ButtonPress.parse("EVENT B4 DOWN count=3")?.button == 4)
    precondition(ButtonPress.parse("EVENT B4 UP held_ms=100") == nil)
    precondition(isDictationCancelLabel("取消听写") && isDictationCancelLabel("Cancel transcription"))
    for forbidden in ["取消", "Cancel", "Stop", "停止任务", "停止听写", "Stop dictation", "Cancel task"] {
        precondition(!isDictationCancelLabel(forbidden), "must never match generic cancellation or stop controls")
    }
    precondition(isClearPromptAccelerator("Ctrl+Alt+Shift+Backspace"))
    precondition(isClearPromptAccelerator("Shift+Control+Option+Backspace"))
    precondition(!isClearPromptAccelerator("Command+Shift+Backspace"))
    precondition(!isClearPromptAccelerator("Ctrl+Alt+Shift+Delete"))
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    precondition(cancelButtonCenter(CGRect(x: 120, y: 150, width: 32, height: 32), inside: window) == CGPoint(x: 136, y: 166))
    for unsafe in [CGRect(x: 90, y: 150, width: 32, height: 32),
                   CGRect(x: 120, y: 150, width: 0, height: 32),
                   CGRect(x: 120, y: 150, width: 500, height: 32),
                   CGRect(x: CGFloat.nan, y: 150, width: 32, height: 32)] {
        precondition(cancelButtonCenter(unsafe, inside: window) == nil, "reject invalid or outside-window click targets")
    }
    precondition(agentLEDMode(bridgeMode: "READY", state: "RUNNING", codexRunning: true) == "RECORDING")
    precondition(agentLEDMode(bridgeMode: "READY", state: "WAITING", codexRunning: true) == "ERROR")
    precondition(agentLEDMode(bridgeMode: "RECORDING", state: "DONE", codexRunning: true) == "READY", "button commands must not fake agent work")
    precondition(agentLEDMode(bridgeMode: "ERROR", state: "DONE", codexRunning: true) == "ERROR", "real bridge fault has priority")
    precondition(agentLEDMode(bridgeMode: "READY", state: nil, codexRunning: true) == "OFFLINE")
    precondition(agentLEDMode(bridgeMode: "READY", state: "RUNNING", codexRunning: false) == "OFFLINE")
    let sample = Data(#"{"schema_version":1,"source":"codex-hook","thread_id":"A","turn_id":"1","state":"WAITING","wait_kind":"question","updated_at":1,"revision":1}"#.utf8)
    precondition(AgentSnapshot.parse(sample)?.state == "WAITING")
    precondition(AgentSnapshot.parse(Data("{}".utf8)) == nil)
    precondition(AgentSnapshot.parse(Data(String(decoding: sample, as: UTF8.self).replacingOccurrences(of: "codex-hook", with: "demo").utf8)) == nil)
    print("PASS: independent four-key input gates, duplicate suppression, safe new-chat URL, exact cancellation labels and bounded click targets. No UI events posted, calls made or chats created.")
} else {
    let app = NSApplication.shared
    let delegate = VoiceBridge()
    app.delegate = delegate
    app.run()
}
