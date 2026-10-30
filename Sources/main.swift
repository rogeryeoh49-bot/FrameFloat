import AppKit
import QuartzCore

// This measures this process's display-link cadence, not another app's rendering.
struct Cadence {
    private var previous: Double?
    private var intervals: [Double] = []
    mutating func reset() { previous = nil; intervals.removeAll() }
    mutating func record(_ time: Double) {
        defer { previous = time }
        guard let last = previous else { return }
        let delta = time - last
        guard delta > 0, delta < 0.5 else { intervals.removeAll(); return }
        intervals.append(delta)
        if intervals.count > 240 { intervals.removeFirst(intervals.count - 240) }
    }
    var hz: Double? {
        guard intervals.count >= 8 else { return nil }
        let recent = Array(intervals.suffix(60))
        return Double(recent.count) / recent.reduce(0, +)
    }
    var milliseconds: Double? { hz.map { 1000 / $0 } }
}

final class GraphView: NSView {
    var values: [Double] = []
    var maximum: Double = 60
    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let path = NSBezierPath()
        for (i, value) in values.enumerated() {
            let p = NSPoint(x: bounds.width * Double(i) / Double(max(values.count - 1, 1)),
                            y: 3 + (bounds.height - 6) * min(value / max(maximum * 1.08, 1), 1))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor(calibratedRed: 0.56, green: 0.91, blue: 0.76, alpha: 1).setStroke()
        path.lineWidth = 1.8
        path.stroke()
    }
}

final class OverlayView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = (NSApp.delegate as? AppDelegate)?.statusItem.menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    private var link: CADisplayLink?
    private var timer: Timer?
    private var cadence = Cadence()
    private var selectedScreen: NSScreen?
    private var lastCallback: Double = 0
    private var clickThrough = false
    private var lockedDisplayID: CGDirectDisplayID?
    private let number = NSTextField(labelWithString: "—")
    private let detail = NSTextField(labelWithString: "等待同步信号…")
    private let screenName = NSTextField(labelWithString: "")
    private let graph = GraphView()
    private var testMode = CommandLine.arguments.contains("--self-test")
    private var totalCallbacks = 0
    private var measuredSamples = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉ Hz"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        connect(to: panel.screen ?? NSScreen.main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateReading()
        }
        if testMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                let rate = cadence.hz ?? 0
                print("SELF-TEST callbacks=\(totalCallbacks) samples=\(measuredSamples) cadence=\(String(format: "%.2f", rate))Hz display=\(selectedScreen?.localizedName ?? "none")")
                let success = totalCallbacks > 20 && measuredSamples > 0 && rate > 1 && rate < 1000
                print(success ? "PASS: live display-link samples and overlay updates" : "FAIL: no valid live cadence")
                fflush(stdout)
                NSApp.terminate(nil)
                if !success { exit(1) }
            }
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makePanel() {
        let size = NSSize(width: 238, height: 154)
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "FrameFloat"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        let root = OverlayView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 0.93).cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        let heading = label("DISPLAY SYNC", size: 10, weight: .semibold, color: .lightGray)
        heading.frame = NSRect(x: 18, y: 122, width: 140, height: 16)
        root.addSubview(heading)
        let indicator = label("●", size: 10, weight: .regular,
            color: NSColor(calibratedRed: 0.56, green: 0.91, blue: 0.76, alpha: 1))
        indicator.frame = NSRect(x: 205, y: 122, width: 15, height: 16)
        root.addSubview(indicator)
        number.font = .monospacedDigitSystemFont(ofSize: 39, weight: .medium)
        number.textColor = .white
        number.frame = NSRect(x: 16, y: 72, width: 157, height: 51)
        root.addSubview(number)
        let unit = label("Hz", size: 16, weight: .medium, color: .lightGray)
        unit.frame = NSRect(x: 181, y: 83, width: 36, height: 25)
        root.addSubview(unit)
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .lightGray
        detail.frame = NSRect(x: 18, y: 57, width: 206, height: 17)
        root.addSubview(detail)
        graph.frame = NSRect(x: 18, y: 27, width: 202, height: 28)
        root.addSubview(graph)
        screenName.font = .systemFont(ofSize: 9)
        screenName.textColor = NSColor(white: 1, alpha: 0.60)
        screenName.lineBreakMode = .byTruncatingTail
        screenName.frame = NSRect(x: 18, y: 9, width: 204, height: 15)
        root.addSubview(screenName)
        panel.contentView = root
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let defaults = UserDefaults.standard
        if let point = defaults.string(forKey: "panelOrigin") {
            let candidate = NSRect(origin: NSPointFromString(point), size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                panel.setFrameOrigin(candidate.origin)
            } else { panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 22, y: visible.maxY - size.height - 22)) }
        } else { panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 22, y: visible.maxY - size.height - 22)) }
        panel.orderFrontRegardless()
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func connect(to screen: NSScreen?) {
        link?.invalidate()
        link = nil
        cadence.reset()
        lastCallback = 0
        graph.values.removeAll()
        number.stringValue = "—"
        selectedScreen = screen
        guard let screen else { detail.stringValue = "没有可用显示器"; return }
        screenName.stringValue = screen.localizedName
        graph.maximum = Double(screen.maximumFramesPerSecond)
        let newLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(max(screen.maximumFramesPerSecond, 1))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    @objc private func tick(_ sender: CADisplayLink) {
        cadence.record(sender.timestamp)
        lastCallback = CACurrentMediaTime()
        totalCallbacks += 1
    }

    private func updateReading() {
        guard let rate = cadence.hz, CACurrentMediaTime() - lastCallback < 1 else {
            number.stringValue = "—"
            detail.stringValue = "等待显示同步信号…"
            statusItem.button?.title = "◉ — Hz"
            return
        }
        measuredSamples += 1
        number.stringValue = String(format: "%.1f", rate)
        detail.stringValue = String(format: "%.2f ms  ·  显示同步频率", 1000 / rate)
        statusItem.button?.title = String(format: "◉ %.0f Hz", rate)
        graph.values.append(rate)
        if graph.values.count > 80 { graph.values.removeFirst() }
        graph.needsDisplay = true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        @discardableResult func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
            value.target = self
            menu.addItem(value)
            return value
        }
        let title = NSMenuItem(title: "FrameFloat · 显示同步监测", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        item(panel.isVisible ? "隐藏浮窗" : "显示浮窗", #selector(toggleOverlay))
        item("鼠标穿透（可从菜单栏关闭）", #selector(toggleClickThrough)).state = clickThrough ? .on : .off
        item("跟随浮窗所在显示器", #selector(followPanel)).state = lockedDisplayID == nil ? .on : .off
        for screen in NSScreen.screens {
            let entry = item(screen.localizedName, #selector(selectScreen(_:)))
            entry.representedObject = NSNumber(value: displayID(screen))
            entry.state = lockedDisplayID == displayID(screen) ? .on : .off
        }
        menu.addItem(.separator())
        item("这是什么读数？", #selector(showAbout))
        item("退出 FrameFloat", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    @objc private func toggleOverlay() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        rebuildMenu()
    }
    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        panel.ignoresMouseEvents = clickThrough
        rebuildMenu()
    }
    @objc private func followPanel() { lockedDisplayID = nil; connect(to: panel.screen); rebuildMenu() }
    @objc private func selectScreen(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.uint32Value,
              let screen = NSScreen.screens.first(where: { displayID($0) == id }) else { return }
        lockedDisplayID = id
        connect(to: screen)
        rebuildMenu()
    }
    @objc private func screensChanged() {
        if let id = lockedDisplayID, let screen = NSScreen.screens.first(where: { displayID($0) == id }) {
            connect(to: screen)
        } else { lockedDisplayID = nil; connect(to: panel.screen ?? NSScreen.main) }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 22,
                                        y: screen.visibleFrame.maxY - panel.frame.height - 22))
        }
        rebuildMenu()
    }
    @objc private func wake() { screensChanged() }
    func windowDidChangeScreen(_ notification: Notification) {
        if lockedDisplayID == nil { connect(to: panel.screen ?? NSScreen.main) }
    }
    func windowDidMove(_ notification: Notification) {
        if !testMode { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin") }
    }
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "这个数字表示什么？"
        alert.informativeText = "FrameFloat 测量本进程收到的显示同步回调频率，按最近约 60 个间隔计算，每 0.25 秒更新。\n\n它不测量其他应用或游戏的 FPS，也不能直接读取面板内部的瞬时物理刷新率。即使其他应用卡顿，这里仍可能显示 60 Hz。\n\n拖动浮窗可移动位置；右键或点击菜单栏可设置鼠标穿透、切换显示器或退出。无需录屏权限。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { link?.invalidate(); timer?.invalidate() }
}

if CommandLine.arguments.contains("--test-math") {
    var metric = Cadence()
    for i in 0...120 { metric.record(Double(i) / 60) }
    precondition(abs((metric.hz ?? 0) - 60) < 0.001)
    metric.reset()
    precondition(metric.hz == nil)
    for i in 0...240 { metric.record(Double(i) / 120) }
    precondition(abs((metric.hz ?? 0) - 120) < 0.001)
    metric.record(10) // Sleep-sized gaps must not produce a misleading low reading.
    precondition(metric.hz == nil)
    print("PASS: 60/120 Hz calculation, reset and long-gap handling")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
