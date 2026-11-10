import AppKit
import QuartzCore

// This measures this process's display-link cadence, not another app's rendering.
struct Cadence {
    private var previous: Double?
    private var intervals: [Double] = []
    private var peakInterval: Double?

    mutating func reset() {
        previous = nil
        intervals.removeAll(keepingCapacity: true)
        peakInterval = nil
    }

    mutating func record(_ time: Double) {
        defer { previous = time }
        guard let last = previous else { return }
        let delta = time - last
        guard delta > 0, delta < 0.5 else { reset(); return }
        peakInterval = max(peakInterval ?? 0, delta)
        intervals.append(delta)
        if intervals.count > 60 { intervals.removeFirst() }
    }

    var hz: Double? {
        guard intervals.count >= 8 else { return nil }
        return Double(intervals.count) / intervals.reduce(0, +)
    }

    mutating func takePeakMilliseconds() -> Double? {
        defer { peakInterval = nil }
        return peakInterval.map { $0 * 1000 }
    }
}

private let mint = NSColor(srgbRed: 0.54, green: 0.94, blue: 0.79, alpha: 1)

final class GraphView: NSView {
    private struct Sample {
        let time: Double
        let milliseconds: Double?
    }

    private let duration: Double = 20
    private var samples: [Sample] = []
    private var now: Double = 0
    var referenceMilliseconds: Double = 1000 / 60

    func reset() {
        samples.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    func append(_ milliseconds: Double?, at time: Double) {
        now = time
        samples.append(Sample(time: time, milliseconds: milliseconds))
        samples.removeAll { time - $0.time > duration }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 8, dy: 6)
        let largest = samples.compactMap(\.milliseconds).max() ?? referenceMilliseconds
        let ceiling = max(referenceMilliseconds * 1.8, largest * 1.08)
        let baselineY = area.minY + area.height * referenceMilliseconds / ceiling
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: area.minX, y: baselineY))
        baseline.line(to: NSPoint(x: area.maxX, y: baselineY))
        baseline.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.26).setStroke()
        baseline.stroke()

        let path = NSBezierPath()
        var lastTime: Double?
        for sample in samples {
            guard let value = sample.milliseconds else { lastTime = nil; continue }
            let point = NSPoint(x: area.maxX - area.width * (now - sample.time) / duration,
                                y: area.minY + area.height * value / ceiling)
            if let lastTime, sample.time - lastTime < 0.75 {
                path.line(to: point)
            } else {
                path.move(to: point)
            }
            lastTime = sample.time
        }
        mint.setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
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
    private var hoverTimer: Timer?
    private var cadence = Cadence()
    private var selectedScreen: NSScreen?
    private var lastCallback: Double = 0
    private var sampleStarted: Double?
    private var clickThrough = false
    private var compact = false
    private var faded = false
    private var lockedDisplayID: CGDirectDisplayID?
    private let number = NSTextField(labelWithString: "—")
    private let detail = NSTextField(labelWithString: "")
    private let screenName = NSTextField(labelWithString: "")
    private let graphReference = NSTextField(labelWithString: "")
    private let miniReading = NSTextField(labelWithString: "— Hz")
    private let graph = GraphView()
    private let testMode = CommandLine.arguments.contains("--self-test")
    private var totalCallbacks = 0
    private var measuredSamples = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        compact = !testMode && defaults.bool(forKey: "compactOverlay")
        clickThrough = !testMode && defaults.bool(forKey: "clickThrough")
        makePanel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉ Hz"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        panel.delegate = self
        panel.ignoresMouseEvents = clickThrough
        if testMode || !defaults.bool(forKey: "menuBarOnly") {
            panel.orderFrontRegardless()
        }
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        connect(to: screenForPanel())
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateReading()
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateHoverMonitoring()
        if testMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                let rate = cadence.hz ?? 0
                print("SELF-TEST callbacks=\(totalCallbacks) samples=\(measuredSamples) cadence=\(String(format: "%.2f", rate))Hz display=\(selectedScreen?.localizedName ?? "none")")
                let success = totalCallbacks > 20 && measuredSamples > 0 && rate > 1 && rate < 1000
                print(success ? "PASS: live display-link samples and overlay updates" : "FAIL: no valid live cadence")
                fflush(stdout)
                if !success { exit(1) }
                NSApp.terminate(nil)
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
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: overlaySize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "FrameFloat"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        configureOverlay()
        let defaults = UserDefaults.standard
        if let point = defaults.string(forKey: "panelOrigin") {
            panel.setFrameOrigin(NSPointFromString(point))
        } else if let screen = NSScreen.main {
            placeInCorner(of: screen)
        }
        keepPanelOnScreen()
    }

    private var overlaySize: NSSize {
        compact ? NSSize(width: 120, height: 36) : NSSize(width: 252, height: 164)
    }

    private func configureOverlay() {
        let root = OverlayView(frame: NSRect(origin: .zero, size: overlaySize))
        root.wantsLayer = true
        root.layer?.cornerRadius = compact ? 18 : 20
        root.layer?.masksToBounds = true
        let background = CAGradientLayer()
        background.frame = root.bounds
        background.colors = [
            NSColor(srgbRed: 0.10, green: 0.16, blue: 0.16, alpha: 0.98).cgColor,
            NSColor(srgbRed: 0.045, green: 0.07, blue: 0.08, alpha: 0.98).cgColor
        ]
        background.startPoint = CGPoint(x: 0, y: 1)
        background.endPoint = CGPoint(x: 1, y: 0)
        root.layer?.addSublayer(background)
        root.layer?.borderWidth = 1
        root.layer?.borderColor = mint.withAlphaComponent(0.21).cgColor

        let indicator = label("●", size: 8, weight: .regular, color: mint)
        indicator.frame = compact ? NSRect(x: 13, y: 12, width: 12, height: 12)
                                  : NSRect(x: 18, y: 135, width: 12, height: 14)
        root.addSubview(indicator)
        if compact {
            miniReading.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            miniReading.textColor = .white
            miniReading.frame = NSRect(x: 27, y: 8, width: 88, height: 20)
            root.addSubview(miniReading)
            panel.contentView = root
            return
        }

        let heading = label("DISPLAY SYNC", size: 10, weight: .semibold, color: mint)
        heading.frame = NSRect(x: 31, y: 133, width: 140, height: 16)
        root.addSubview(heading)
        number.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        number.textColor = .white
        number.frame = NSRect(x: 15, y: 79, width: 147, height: 52)
        root.addSubview(number)
        let unit = label("Hz", size: 17, weight: .medium, color: mint)
        unit.frame = NSRect(x: 166, y: 92, width: 32, height: 24)
        root.addSubview(unit)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detail.textColor = NSColor.white.withAlphaComponent(0.76)
        detail.frame = NSRect(x: 18, y: 65, width: 214, height: 16)
        root.addSubview(detail)
        graph.frame = NSRect(x: 17, y: 25, width: 218, height: 35)
        graph.wantsLayer = true
        graph.layer?.cornerRadius = 8
        graph.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        root.addSubview(graph)
        screenName.font = .systemFont(ofSize: 9)
        screenName.textColor = NSColor(white: 1, alpha: 0.60)
        screenName.lineBreakMode = .byTruncatingTail
        screenName.frame = NSRect(x: 18, y: 7, width: 120, height: 15)
        root.addSubview(screenName)
        graphReference.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        graphReference.textColor = NSColor.white.withAlphaComponent(0.60)
        graphReference.alignment = .right
        graphReference.frame = NSRect(x: 138, y: 7, width: 96, height: 15)
        root.addSubview(graphReference)
        panel.contentView = root
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func screenForPanel() -> NSScreen? {
        let intersectingScreens = NSScreen.screens.filter { $0.visibleFrame.intersects(panel.frame) }
        return intersectingScreens.max {
            let a = $0.visibleFrame.intersection(panel.frame)
            let b = $1.visibleFrame.intersection(panel.frame)
            return a.width * a.height < b.width * b.height
        }
    }

    private func placeInCorner(of screen: NSScreen) {
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 22,
                                     y: visible.maxY - panel.frame.height - 22))
    }

    private func keepPanelOnScreen() {
        guard let screen = screenForPanel() else {
            if let main = NSScreen.main { placeInCorner(of: main) }
            return
        }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        let y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        let origin = NSPoint(x: x, y: y)
        if origin != frame.origin { panel.setFrameOrigin(origin) }
    }

    private func measurementScreen() -> NSScreen? {
        if let id = lockedDisplayID {
            if let screen = NSScreen.screens.first(where: { displayID($0) == id }) { return screen }
            lockedDisplayID = nil
        }
        return screenForPanel() ?? NSScreen.main
    }

    private func connect(to screen: NSScreen?) {
        link?.invalidate()
        link = nil
        cadence.reset()
        lastCallback = 0
        sampleStarted = nil
        graph.reset()
        selectedScreen = screen
        screenName.stringValue = screen?.localizedName ?? ""
        graphReference.stringValue = ""
        render(rate: nil)
        guard let screen else { return }
        let maximum = Float(max(screen.maximumFramesPerSecond, 1))
        let modeRate = CGDisplayCopyDisplayMode(displayID(screen))?.refreshRate ?? 0
        graph.referenceMilliseconds = 1000 / (modeRate > 0 ? modeRate : Double(maximum))
        graphReference.stringValue = String(format: "%.2f ms REF", graph.referenceMilliseconds)
        let newLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        newLink.add(to: .main, forMode: .common)
        link = newLink
        if !panel.isVisible { startMenuSample(at: CACurrentMediaTime()) }
    }

    @objc private func tick(_ sender: CADisplayLink) {
        cadence.record(sender.timestamp)
        lastCallback = CACurrentMediaTime()
        if testMode { totalCallbacks += 1 }
    }

    private func startMenuSample(at time: Double) {
        sampleStarted = time
        cadence.reset()
        lastCallback = 0
        link?.isPaused = false
    }

    private func updateReading() {
        let now = CACurrentMediaTime()
        let rate = now - lastCallback < 1 ? cadence.hz : nil
        if !panel.isVisible {
            guard let link, let started = sampleStarted else { return }
            if now - started >= 4 {
                startMenuSample(at: now)
            } else if !link.isPaused && now - started >= 0.5 {
                link.isPaused = true
                render(rate: rate)
            }
            return
        }

        if testMode && rate != nil { measuredSamples += 1 }
        let peak = cadence.takePeakMilliseconds()
        if !compact { graph.append(rate == nil ? nil : peak, at: now) }
        render(rate: rate)
    }

    private func render(rate: Double?) {
        let title: String
        if let rate {
            let format = panel.isVisible ? "◉ %.0f Hz" : "◉ ≈%.0f Hz"
            title = String(format: format, rate)
        } else {
            title = "◉ — Hz"
        }
        if statusItem.button?.title != title { statusItem.button?.title = title }
        guard panel.isVisible else { return }
        let reading = rate.map { String(format: "%.1f", $0) } ?? "—"
        if compact {
            miniReading.stringValue = "\(reading) Hz"
        } else {
            number.stringValue = reading
            detail.stringValue = rate.map { String(format: "%.2f ms  ·  同步间隔", 1000 / $0) }
                ?? (selectedScreen == nil ? "没有可用显示器" : "等待显示同步信号…")
        }
    }

    private func updateHoverMonitoring() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        updateHover()
        guard clickThrough && panel.isVisible else { return }
        // Click-through windows don't receive mouse-entered events.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateHover() }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        let shouldFade = clickThrough && panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        guard shouldFade != faded else { return }
        faded = shouldFade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = shouldFade ? 0.20 : 1
        }
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
        item("详细浮窗", #selector(showFull)).state = panel.isVisible && !compact ? .on : .off
        item("迷你浮窗", #selector(showMini)).state = panel.isVisible && compact ? .on : .off
        item("仅菜单栏（间歇采样）", #selector(showMenuOnly)).state = panel.isVisible ? .off : .on
        menu.addItem(.separator())
        item("鼠标穿透 · 划过时淡出", #selector(toggleClickThrough)).state = clickThrough ? .on : .off
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

    @objc private func showFull() { showOverlay(compact: false) }
    @objc private func showMini() { showOverlay(compact: true) }

    private func showOverlay(compact: Bool) {
        let wasVisible = panel.isVisible
        if compact != self.compact {
            let anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
            self.compact = compact
            let size = overlaySize
            panel.setFrame(NSRect(x: anchor.x - size.width, y: anchor.y - size.height,
                                  width: size.width, height: size.height), display: false)
            configureOverlay()
            graph.reset()
        }
        keepPanelOnScreen()
        panel.orderFrontRegardless()
        if !wasVisible { connect(to: measurementScreen()) }
        updateReading()
        updateHoverMonitoring()
        if !testMode {
            UserDefaults.standard.set(compact, forKey: "compactOverlay")
            UserDefaults.standard.set(false, forKey: "menuBarOnly")
        }
        rebuildMenu()
    }

    @objc private func showMenuOnly() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        graph.reset()
        render(rate: cadence.hz)
        startMenuSample(at: CACurrentMediaTime())
        updateHoverMonitoring()
        if !testMode { UserDefaults.standard.set(true, forKey: "menuBarOnly") }
        rebuildMenu()
    }

    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        panel.ignoresMouseEvents = clickThrough
        updateHoverMonitoring()
        if !testMode { UserDefaults.standard.set(clickThrough, forKey: "clickThrough") }
        rebuildMenu()
    }
    @objc private func followPanel() { lockedDisplayID = nil; connect(to: measurementScreen()); rebuildMenu() }
    @objc private func selectScreen(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.uint32Value,
              let screen = NSScreen.screens.first(where: { displayID($0) == id }) else { return }
        lockedDisplayID = id
        connect(to: screen)
        rebuildMenu()
    }
    @objc private func screensChanged() {
        keepPanelOnScreen()
        connect(to: measurementScreen())
        updateHover()
        rebuildMenu()
    }
    @objc private func wake() { screensChanged() }
    func windowDidChangeScreen(_ notification: Notification) {
        guard lockedDisplayID == nil else { return }
        let screen = panel.screen ?? measurementScreen()
        if screen.map(displayID) != selectedScreen.map(displayID) { connect(to: screen) }
    }
    func windowDidMove(_ notification: Notification) {
        if !testMode { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin") }
    }
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "这个数字表示什么？"
        alert.informativeText = "主读数显示最近 60 个显示同步回调间隔的平均频率。曲线记录过去 20 秒里，每 0.25 秒内最长的同步间隔。虚线是显示器的参考间隔。\n\n仅菜单栏模式约每 4 秒短暂采样，≈ 表示最近一次采样。\n\n读数反映 FrameFloat 收到的同步回调。即使其他应用卡顿，这里仍可能显示 60 Hz。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        link?.invalidate()
        timer?.invalidate()
        hoverTimer?.invalidate()
    }
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
