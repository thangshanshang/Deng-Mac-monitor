import AppKit
import SwiftUI
import Darwin

struct Snapshot: Equatable {
    var cpu: Double?
    var gpu: Double?
    var memory: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var swap: Double?
    var ane: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var systemPower: Double?
    var aneMetrics = ANEReading()
}

@MainActor final class Monitor: ObservableObject {
    @Published var data = Snapshot()
    var aneMetrics: ANEReading { data.aneMetrics }
    private var latest = Snapshot()
    private var panelsVisible = false
    var onSystemPower: ((Double?) -> Void)?

    func setPanelsVisible(_ visible: Bool) {
        guard panelsVisible != visible else { return }
        panelsVisible = visible
        if visible {
            _ = sampleCPU()
            latest.aneMetrics = aneHardware?.sample() ?? ANEReading()
            if data != latest { data = latest }
        }
    }

    private func clearCollectorData() {
        latest = Snapshot(cpu: latest.cpu)
        if panelsVisible { data = latest }
        onSystemPower?(nil)
    }
    private var aneHardware: ANEHardware?
    @Published var status = "正在连接采集器"
    private var updated: Date?
    private var process: Process?
    private var timer: Timer?
    private var lastCPU: [UInt64]?
    private var pending = Data()
    private var retryAt = Date.distantPast
    private var startedAt = Date.distantPast
    let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    func start() {
        aneHardware = ANEHardware()
        _ = sampleCPU()
        launchCollector()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.process == nil && Date() > self.retryAt { self.launchCollector() }
                if self.process != nil && Date().timeIntervalSince(self.updated ?? self.startedAt) > 8 {
                    self.clearCollectorData()
                    self.status = "采集暂无响应 · 正在重连"
                    self.process?.terminate()
                }
            }
        }
        timer?.tolerance = 0.2
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { lastCPU = ticks }
        guard let previous = lastCPU, zip(ticks, previous).allSatisfy({ $0 >= $1 }) else { return nil }
        let delta = zip(ticks, previous).map { $0 - $1 }
        let total = delta.reduce(0, +)
        return total > 0 ? 1 - Double(delta[2]) / Double(total) : nil
    }

    private func launchCollector() {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("macmon").path, "/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            status = "未找到采集器 · 请安装 macmon"
            retryAt = Date().addingTimeInterval(10)
            return
        }
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = ["pipe", "-i", "1000"]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        pending.removeAll()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.receive(chunk) }
        }
        child.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.clearCollectorData()
                self.status = "采集已断开 · 正在重连"
                self.retryAt = Date().addingTimeInterval(4)
            }
        }
        do {
            try child.run()
            process = child
            startedAt = Date()
            updated = nil
            status = "正在采样"
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            status = "采集器无法启动"
            retryAt = Date().addingTimeInterval(10)
        }
    }

    private func receive(_ bytes: Data) {
        pending.append(bytes)
        while let end = pending.firstIndex(of: 10) {
            let line = pending.subdata(in: 0..<end)
            pending.removeSubrange(0...end)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            apply(json)
        }
        if pending.count > 1_000_000 { pending.removeAll() }
    }

    func apply(_ json: [String: Any]) {
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func n(_ key: String) -> Double? { number(json[key]) }
        func ratio(_ key: String) -> Double? { n(key).map { min(1, max(0, $0)) } }
        var next = Snapshot(cpu: latest.cpu)
        if panelsVisible {
            next.cpu = sampleCPU() ?? latest.cpu
            next.aneMetrics = aneHardware?.sample() ?? ANEReading()
        }
        next.gpu = ratio("gpu_active_ratio")
        next.ane = n("ane_power")
        next.cpuPower = n("cpu_power")
        next.gpuPower = n("gpu_power")
        next.systemPower = n("sys_power").flatMap { $0 >= 0 ? $0 : nil }
        if let memory = json["memory"] as? [String: Any] {
            next.memoryUsed = number(memory["ram_usage"])
            next.memoryTotal = number(memory["ram_total"])
            next.swap = number(memory["swap_usage"])
            if let used = next.memoryUsed, let total = next.memoryTotal, total > 0 {
                next.memory = min(1, max(0, used / total))
            }
        }
        if let temp = json["temp"] as? [String: Any] {
            next.cpuTemp = number(temp["cpu_temp_avg"])
            next.gpuTemp = number(temp["gpu_temp_avg"])
        }
        latest = next
        if panelsVisible, data != next { data = next }
        onSystemPower?(next.systemPower)
        updated = Date()
        if status != "实时监测 · 每秒更新" { status = "实时监测 · 每秒更新" }
    }

    func stop() {
        timer?.invalidate()
        process?.terminationHandler = nil
        process?.terminate()
    }
}

func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
func watts(_ value: Double?) -> String { value.map { String(format: "%.2f W", $0) } ?? "—" }
func systemWatts(_ value: Double?) -> String { value.map { String(format: "%.1f W", $0) } ?? "— W" }
func bandwidth(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value == 0 { return "0 MB/s" }
    if value < 1 { return String(format: "%.1f MB/s", value * 1000) }
    return String(format: "%.2f GB/s", value)
}
func temperature(_ value: Double?) -> String { value.map { String(format: "%.0f°", $0) } ?? "—" }
func gb(_ value: Double?) -> String { value.map { String(format: "%.1f", $0 / 1_073_741_824) } ?? "—" }

struct MetricRow: View {
    let title: String
    let value: String
    let detail: String
    var ratio: Double? = nil
    var showsProgress = true
    var tint: Color = .blue
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: compact ? 19 : 22, weight: .medium, design: .rounded)).monospacedDigit()
            }
            if showsProgress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(tint.opacity(0.8)).frame(width: geometry.size.width * min(1, max(0, ratio ?? 0)))
                    }
                }.frame(height: 3)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.vertical, compact ? 8 : 12)
    }
}

@MainActor final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    @Published var liquidGlass: Bool {
        didSet {
            UserDefaults.standard.set(liquidGlass, forKey: "appearance.liquidGlass")
            onChange?()
        }
    }
    @Published var showOwnership: Bool {
        didSet {
            UserDefaults.standard.set(showOwnership, forKey: "appearance.showOwnership")
            onChange?()
        }
    }
    @Published var transparentSwitch: Bool {
        didSet {
            UserDefaults.standard.set(transparentSwitch, forKey: "appearance.transparentSwitch")
            onChange?()
        }
    }
    var onChange: (() -> Void)?
    private init() {
        let defaults = UserDefaults.standard
        liquidGlass = defaults.object(forKey: "appearance.liquidGlass") as? Bool ?? true
        showOwnership = defaults.object(forKey: "appearance.showOwnership") as? Bool ?? true
        transparentSwitch = defaults.object(forKey: "appearance.transparentSwitch") as? Bool ?? true
    }
}

// Neutral glass styling with native Toggle semantics and standard keyboard activation.
struct GlassSwitchButtonStyle: ButtonStyle {
    let isOn: Bool
    let transparentTrack: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var thumb: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.white.opacity(colorScheme == .dark ? 0.12 : 0.36))
                .glassEffect(.clear, in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Capsule()
                .fill(isOn ? (transparentTrack ? Color.primary.opacity(0.12) : Color.blue.opacity(0.88)) : Color.primary.opacity(0.055))
                .overlay {
                    Capsule().strokeBorder(.white.opacity(isOn ? 0.48 : 0.24), lineWidth: 0.5)
                }
            thumb
                .frame(width: configuration.isPressed ? 25 : 21, height: 16)
                .phaseAnimator([1.0, 1.28, 0.94, 1.0], trigger: isOn) { content, phase in
                    content.scaleEffect(x: reduceMotion ? 1 : phase, y: reduceMotion ? 1 : 1 / sqrt(phase))
                } animation: { _ in
                    reduceMotion ? .linear(duration: 0) : .spring(response: 0.18, dampingFraction: 0.65)
                }
                .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                .offset(x: isOn ? 9 : -9)
        }
        .frame(width: 44, height: 20)
        .contentShape(Capsule())
        .scaleEffect(configuration.isPressed ? 1.025 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62), value: isOn)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NeutralGlassToggleStyle: ToggleStyle {
    let transparentTrack: Bool
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Color.clear.frame(width: 44, height: 20)
        }
        .buttonStyle(GlassSwitchButtonStyle(isOn: configuration.isOn, transparentTrack: transparentTrack))
        .accessibilityRepresentation {
            Toggle("液态玻璃效果", isOn: configuration.$isOn).toggleStyle(.switch)
        }
    }
}

struct GlassToggle: View {
    @ObservedObject var settings = AppearanceSettings.shared
    var body: some View {
        Toggle("液态玻璃效果", isOn: $settings.liquidGlass)
            .labelsHidden().toggleStyle(NeutralGlassToggleStyle(transparentTrack: settings.transparentSwitch))
            .help("液态玻璃效果：开启使用原生玻璃，关闭使用磨砂")
    }
}

// One active native surface: switching materials never retains both glass backings.
@MainActor final class GlassPanelController: NSViewController {
    final class MetricsHost: NSHostingView<Panel> {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    let preferredSize: NSSize
    private let host: MetricsHost
    private var surface: NSView?
    private(set) var usingLiquidGlass = false
    init(panel: Panel, titlebar: Bool = false) {
        var panel = panel
        panel.titlebar = titlebar
        host = MetricsHost(rootView: panel)
        host.safeAreaRegions = []
        preferredSize = host.fittingSize
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(origin: .zero, size: preferredSize))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        applyAppearance()
    }
    func applyAppearance() {
        let enabled = AppearanceSettings.shared.liquidGlass
        if surface != nil, usingLiquidGlass == enabled { return }
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = nil
        }
        host.removeFromSuperview()
        surface?.removeFromSuperview()
        let bounds = view.bounds
        if #available(macOS 26.0, *), enabled {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear
            glass.cornerRadius = 24
            glass.contentView = host
            surface = glass
            usingLiquidGlass = true
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 24
            material.layer?.masksToBounds = true
            material.addSubview(host)
            surface = material
            usingLiquidGlass = false
        }
        host.frame = bounds
        if let surface {
            surface.autoresizingMask = [.width, .height]
            view.addSubview(surface)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct Panel: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings = AppearanceSettings.shared
    var compact = false
    var titlebar = false
    var onClose: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Silicon").font(.system(size: 20, weight: .semibold))
                    Text(monitor.chip).font(.system(size: 11)).foregroundStyle(.secondary).help(monitor.status)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(systemWatts(monitor.data.systemPower))
                        .font(.system(size: compact ? 17 : 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("整机总功耗").font(.system(size: 10)).foregroundStyle(.secondary)
                }.help("系统传感器报告的整机功耗，不是 CPU、GPU 与 ANE 功耗相加。不可用时显示 — W。")
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 4)
                        .help("关闭面板（Esc）").accessibilityLabel("关闭面板")
                }
            }.padding(.bottom, compact ? 10 : 16)
            Divider()
            MetricRow(title: "CPU", value: percent(monitor.data.cpu), detail: "\(watts(monitor.data.cpuPower))   ·   \(temperature(monitor.data.cpuTemp))", ratio: monitor.data.cpu, tint: .blue, compact: compact)
            Divider()
            MetricRow(title: "GPU", value: percent(monitor.data.gpu), detail: "活动率   ·   \(watts(monitor.data.gpuPower))   ·   \(temperature(monitor.data.gpuTemp))", ratio: monitor.data.gpu, tint: .teal, compact: compact)
            Divider()
            MetricRow(title: "内存", value: percent(monitor.data.memory), detail: "\(gb(monitor.data.memoryUsed)) / \(gb(monitor.data.memoryTotal)) GB   ·   Swap \(gb(monitor.data.swap)) GB", ratio: monitor.data.memory, tint: .indigo, compact: compact)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                MetricRow(title: "Neural Engine", value: bandwidth(monitor.aneMetrics.totalGBs), detail: monitor.aneMetrics.estimated ? "内存吞吐 · 估算" : "内存吞吐 · 读写合计", showsProgress: false, compact: compact)
                    .padding(.bottom, -8)
                HStack {
                    Text("读 " + bandwidth(monitor.aneMetrics.readGBs))
                    Spacer()
                    Text("写 " + bandwidth(monitor.aneMetrics.writeGBs))
                }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                HStack {
                    Text("活动率 " + (monitor.aneMetrics.activity.map { percent($0) } ?? "不可用"))
                        .help("ANE 簇处于 ACT 状态的时间比例，显示最忙簇；此系统未提供通道时显示不可用。不是算力占用率。")
                    Spacer()
                    Text("功耗 " + watts(monitor.data.ane))
                }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 6) {
                GlassToggle()
                Text("液态玻璃效果").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if settings.showOwnership {
                    Text("@太行山上").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 22)
            .padding(.top, 8)
        }
        .padding(.horizontal, compact ? 16 : 22)
        .padding(.top, (compact ? 16 : 18) + (titlebar ? 28 : 0))
        .padding(.bottom, 16)
        .frame(width: compact ? 300 : 330)
        .fixedSize(horizontal: false, vertical: true)

    }
}

@MainActor final class MenuPanel: NSPanel {
    var closeAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { closeAction?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeAction?() } else { super.keyDown(with: event) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuPanel?
    private var mainWindow: NSWindow?
    private var globalClick: Any?
    private var localClick: Any?
    private var resignObserver: NSObjectProtocol?
    private var glassMenuItem: NSMenuItem!
    private var ownershipMenuItem: NSMenuItem!
    private var switchColorMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "Silicon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = false
                button.image = icon
                NSApp.applicationIconImage = NSImage(contentsOf: url)
            }
            button.imagePosition = .imageLeading
            button.title = " — W"
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = "整机总功耗 · 点击展开或收起面板"
            button.setAccessibilityLabel("邓眼瞎 整机功耗")
        }
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        menu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        let show = NSMenuItem(title: "显示监测窗口", action: #selector(revealWindow), keyEquivalent: "1")
        show.target = self
        applicationMenu.addItem(show)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出邓眼瞎", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "设置")
        glassMenuItem = NSMenuItem(title: "液态玻璃效果", action: #selector(toggleGlass), keyEquivalent: "")
        switchColorMenuItem = NSMenuItem(title: "透明开关底色", action: #selector(toggleSwitchColor), keyEquivalent: "")
        switchColorMenuItem.target = self
        ownershipMenuItem = NSMenuItem(title: "显示所有权", action: #selector(toggleOwnership), keyEquivalent: "")
        glassMenuItem.target = self
        ownershipMenuItem.target = self
        settingsMenu.addItem(glassMenuItem)
        settingsMenu.addItem(switchColorMenuItem)
        settingsMenu.addItem(ownershipMenuItem)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        NSApp.mainMenu = menu
        AppearanceSettings.shared.onChange = { [weak self] in self?.applyAppearanceSettings() }
        applyAppearanceSettings()
        monitor.onSystemPower = { [weak self] power in
            guard let button = self?.statusItem.button else { return }
            let title = " " + systemWatts(power)
            if button.title != title { button.title = title }
        }
        monitor.start()
        if !CommandLine.arguments.contains("--export-preview") || CommandLine.arguments.contains("--check-window") { showMainWindow() }
        if let flag = CommandLine.arguments.firstIndex(of: "--export-preview"), CommandLine.arguments.count > flag + 1 {
            let path = CommandLine.arguments[flag + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                monitor.setPanelsVisible(true)
                let renderer = ImageRenderer(content: Panel(monitor: monitor, compact: true, onClose: {}).environment(\.colorScheme, .light))
                renderer.scale = 2
                if let image = renderer.cgImage {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                // Verify the real menu panel's geometry and both toggle/Escape dismissal paths.
                mainWindow?.orderOut(nil)
                showMenuPanel()
                let firstVisible = menuPanel?.isVisible == true
                let size = menuPanel?.frame.size ?? .zero
                let fits = menuPanel.map { panel in panel.screen.map { $0.visibleFrame.contains(panel.frame) } ?? false } ?? false
                toggle()
                let toggledClosed = menuPanel == nil
                showMenuPanel()
                menuPanel?.cancelOperation(nil)
                let escapeClosed = menuPanel == nil
                print("Menu check: visible=\(firstVisible), width=\(size.width), height=\(size.height), fitsScreen=\(fits), toggleClosed=\(toggledClosed), escapeClosed=\(escapeClosed)")
                print("Power check: system=\(systemWatts(monitor.data.systemPower)), menu=\(statusItem.button?.title ?? ""), icon=\(statusItem.button?.image != nil)")
                let valid = firstVisible && fits && toggledClosed && escapeClosed && size.width == 300 && size.height < 500 && monitor.data.systemPower != nil
                monitor.stop()
                exit(valid ? 0 : 1)
            }
        }
    }

    private func showMainWindow() {
        hideMenuPanel()
        if mainWindow == nil {
            let controller = GlassPanelController(panel: Panel(monitor: monitor), titlebar: true)
            let window = NSWindow(contentViewController: controller)
            window.title = "Silicon"
            window.delegate = self
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.setFrame(NSRect(origin: .zero, size: controller.preferredSize), display: false)
            window.center()
            mainWindow = window
        }
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        updateVisibility()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    @objc private func toggleGlass() {
        AppearanceSettings.shared.liquidGlass.toggle()
    }
    @objc private func toggleSwitchColor() {
        AppearanceSettings.shared.transparentSwitch.toggle()
    }
    @objc private func toggleOwnership() {
        AppearanceSettings.shared.showOwnership.toggle()
    }
    private func applyAppearanceSettings() {
        let settings = AppearanceSettings.shared
        glassMenuItem?.state = settings.liquidGlass ? .on : .off
        ownershipMenuItem?.state = settings.showOwnership ? .on : .off
        switchColorMenuItem?.state = settings.transparentSwitch ? .on : .off
        (mainWindow?.contentViewController as? GlassPanelController)?.applyAppearance()
        (menuPanel?.contentViewController as? GlassPanelController)?.applyAppearance()
    }
    @objc private func revealWindow() { showMainWindow() }
    @objc private func toggle() {
        if menuPanel?.isVisible == true { hideMenuPanel() } else { showMenuPanel() }
    }
    private func showMenuPanel() {
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        if menuPanel == nil {
            let controller = GlassPanelController(panel: Panel(monitor: monitor, compact: true, onClose: { [weak self] in self?.hideMenuPanel() }))
            let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.contentViewController = controller
            panel.setContentSize(controller.preferredSize)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.closeAction = { [weak self] in self?.hideMenuPanel() }
            menuPanel = panel
        }
        guard let panel = menuPanel else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? statusWindow.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        let x = min(max(anchor.maxX - size.width, visible.minX), visible.maxX - size.width)
        let y = min(max(anchor.minY - size.height - 7, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        updateVisibility()
        installDismissal()
    }
    private func installDismissal() {
        removeDismissal()
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideMenuPanel() }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown, event.keyCode == 53, self.menuPanel?.isVisible == true {
                    self.hideMenuPanel()
                    return true
                }
                if event.type != .keyDown, event.window !== self.menuPanel, event.window !== self.statusItem.button?.window { self.hideMenuPanel() }
                return false
            }
            return swallow ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hideMenuPanel() }
        }
    }
    private func hideMenuPanel() {
        menuPanel?.orderOut(nil)
        removeDismissal()
        menuPanel = nil
        updateVisibility()
    }
    private func removeDismissal() {
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalClick = nil
        localClick = nil
        resignObserver = nil
    }
    private func updateVisibility() {
        let mainVisible = mainWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        monitor.setPanelsVisible(mainVisible || menuPanel?.isVisible == true)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow {
            mainWindow = nil
            updateVisibility()
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }

    func applicationWillTerminate(_ notification: Notification) {
        removeDismissal()
        monitor.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
