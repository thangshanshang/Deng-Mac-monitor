import AppKit
import SwiftUI
import Darwin

struct Snapshot {
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
}

@MainActor final class Monitor: ObservableObject {
    @Published var data = Snapshot()
    @Published var aneMetrics = ANEReading()
    private var aneHardware: ANEHardware?
    @Published var status = "正在连接采集器"
    @Published var updated: Date?
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
        sampleCPU()
        launchCollector()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sampleCPU()
                self.aneMetrics = self.aneHardware?.sample() ?? ANEReading()
                if self.process == nil && Date() > self.retryAt { self.launchCollector() }
                if self.process != nil && Date().timeIntervalSince(self.updated ?? self.startedAt) > 8 {
                    self.data = Snapshot(cpu: self.data.cpu)
                    self.status = "采集暂无响应 · 正在重连"
                    self.process?.terminate()
                }
            }
        }
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let ticks = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { lastCPU = ticks }
        guard let previous = lastCPU, zip(ticks, previous).allSatisfy({ $0 >= $1 }) else { return }
        let delta = zip(ticks, previous).map { $0 - $1 }
        let total = delta.reduce(0, +)
        if total > 0 { data.cpu = 1 - Double(delta[2]) / Double(total) }
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
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.receive(chunk) }
        }
        child.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.data = Snapshot(cpu: self.data.cpu)
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
        var next = Snapshot(cpu: data.cpu)
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
        data = next
        updated = Date()
        status = "实时监测 · 每秒更新"
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
    var tint: Color = .blue
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: compact ? 19 : 22, weight: .medium, design: .rounded)).monospacedDigit()
            }
            if let ratio {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(tint.opacity(0.8)).frame(width: geometry.size.width * min(1, max(0, ratio)))
                    }
                }.frame(height: 3)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.vertical, compact ? 8 : 12)
    }
}

// One continuous glass surface keeps the metrics readable and avoids stacked glass.
struct MonitorGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct Panel: View {
    @ObservedObject var monitor: Monitor
    var compact = false
    var onClose: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Silicon").font(.system(size: 20, weight: .semibold))
                    Text(monitor.chip).font(.system(size: 11)).foregroundStyle(.secondary)
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
                MetricRow(title: "Neural Engine", value: bandwidth(monitor.aneMetrics.totalGBs), detail: monitor.aneMetrics.estimated ? "内存吞吐 · 估算" : "内存吞吐 · 读写合计", compact: compact)
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
            }.padding(.bottom, compact ? 10 : 14)
            Divider()
            HStack {
                Text(monitor.status).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, compact ? 10 : 14)
        }
        .padding(compact ? 16 : 22)
        .frame(width: compact ? 300 : 330)
        .modifier(MonitorGlass())
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuPanel?
    private var mainWindow: NSWindow?
    private var refresh: Timer?
    private var globalClick: Any?
    private var localClick: Any?
    private var resignObserver: NSObjectProtocol?

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
        monitor.start()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.button?.title = " " + systemWatts(self.monitor.data.systemPower)
            }
        }
        if !CommandLine.arguments.contains("--export-preview") || CommandLine.arguments.contains("--check-window") { showMainWindow() }
        if let flag = CommandLine.arguments.firstIndex(of: "--export-preview"), CommandLine.arguments.count > flag + 1 {
            let path = CommandLine.arguments[flag + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
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
                let toggledClosed = menuPanel?.isVisible == false
                showMenuPanel()
                menuPanel?.cancelOperation(nil)
                let escapeClosed = menuPanel?.isVisible == false
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
            let controller = NSHostingController(rootView: Panel(monitor: monitor))
            let window = NSWindow(contentViewController: controller)
            window.title = "Silicon"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.setContentSize(controller.view.fittingSize)
            window.center()
            mainWindow = window
        }
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    @objc private func toggle() {
        if menuPanel?.isVisible == true { hideMenuPanel() } else { showMenuPanel() }
    }
    private func showMenuPanel() {
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        if menuPanel == nil {
            let controller = NSHostingController(rootView: Panel(monitor: monitor, compact: true, onClose: { [weak self] in self?.hideMenuPanel() }))
            let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentViewController = controller
            panel.setContentSize(controller.view.fittingSize)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = 24
            panel.contentView?.layer?.masksToBounds = true
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
        panel.orderFrontRegardless()
        panel.makeKey()
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
    }
    private func removeDismissal() {
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalClick = nil
        localClick = nil
        resignObserver = nil
    }
    func applicationWillTerminate(_ notification: Notification) {
        refresh?.invalidate()
        removeDismissal()
        monitor.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
