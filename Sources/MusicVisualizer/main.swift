import AppKit
import Darwin
import MediaRemoteAdapter
import MusicVisualizerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var model = VisualizerModel()
    private var hoverTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showPanel()
    }

    private func showPanel() {
        model.notch = NotchMetrics(screen: NSScreen.main)
        model.openSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        let size = model.windowSize
        let frame = centeredTopFrame(size: size)
        model.windowFrame = frame
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let hostingView = VisualizerHostingView(rootView: VisualizerView(model: model))
        hostingView.model = model
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.panel = panel
        startHoverMonitor(panel)
        DispatchQueue.main.async {
            self.model.startMediaUpdates()
        }
    }

    private func centeredTopFrame(size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func startHoverMonitor(_ panel: NSPanel) {
        hoverTimer?.invalidate()
        hoverTimer = Timer(timeInterval: 0.05, target: self, selector: #selector(pollHover), userInfo: nil, repeats: true)
        RunLoop.main.add(hoverTimer!, forMode: .common)
    }

    @objc private func pollHover() {
        guard let panel else { return }
        let shouldReceiveMouse = model.updatePointer(at: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !shouldReceiveMouse
    }

    private func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 190),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Settings"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
        settingsWindow.contentView = NSHostingView(rootView: SettingsView(model: model))
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = settingsWindow
    }
}

@MainActor
final class VisualizerHostingView<Content: View>: NSHostingView<Content> {
    weak var model: VisualizerModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model else { return super.hitTest(point) }
        let size = model.visualSize
        let visibleRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        ).insetBy(dx: -model.hoverPadding, dy: -model.hoverPadding)

        return visibleRect.contains(point) ? super.hitTest(point) : nil
    }
}

private final class DataAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ incoming: Data) {
        lock.lock()
        data.append(incoming)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

struct NotchMetrics {
    let width: CGFloat
    let topInset: CGFloat

    init(screen: NSScreen?) {
        guard
            let screen,
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea,
            !left.isEmpty,
            !right.isEmpty
        else {
            width = 96
            topInset = 37
            return
        }

        width = min(240, max(120, right.minX - left.maxX))
        topInset = screen.safeAreaInsets.top
    }
}

struct SystemMonitorSnapshot {
    var cpuUsage: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0

    var memoryUsage: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    var cpuText: String {
        "\(Int(cpuUsage.rounded()))%"
    }

    var memoryText: String {
        String(format: "%.1f GB", Double(memoryUsedBytes) / 1_073_741_824)
    }
}

final class SystemMonitorSampler {
    private var previousCPU: host_cpu_load_info_data_t?

    func sample() -> SystemMonitorSnapshot {
        let memory = memoryUsage()
        return SystemMonitorSnapshot(
            cpuUsage: cpuUsage(),
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total
        )
    }

    private func cpuUsage() -> Double {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer { previousCPU = load }
        guard let previousCPU else { return 0 }

        let previousActive = previousCPU.cpu_ticks.0 + previousCPU.cpu_ticks.1 + previousCPU.cpu_ticks.3
        let currentActive = load.cpu_ticks.0 + load.cpu_ticks.1 + load.cpu_ticks.3
        let previousTotal = previousActive + previousCPU.cpu_ticks.2
        let currentTotal = currentActive + load.cpu_ticks.2
        let totalDelta = currentTotal - previousTotal
        guard totalDelta > 0 else { return 0 }

        return Double(currentActive - previousActive) / Double(totalDelta) * 100
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, totalMemoryBytes()) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let total = totalMemoryBytes()
        let free = UInt64(stats.free_count + stats.speculative_count) * UInt64(pageSize)
        return (total > free ? total - free : 0, total)
    }

    private func totalMemoryBytes() -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        return total
    }
}

@MainActor
final class VisualizerModel: NSObject, ObservableObject {
    @Published var state = TrackState()
    @Published var levels: [Double] = [0.25, 0.55, 0.85, 0.45, 0.7]
    @Published var notch = NotchMetrics(screen: NSScreen.main)
    @Published var artwork: NSImage?
    @Published var elapsedSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var systemMonitorSnapshot = SystemMonitorSnapshot()
    @Published var systemMonitorEnabled = UserDefaults.standard.bool(forKey: "macResourceMonitorEnabled") {
        didSet {
            UserDefaults.standard.set(systemMonitorEnabled, forKey: "macResourceMonitorEnabled")
            updateSystemMonitorTimer()
        }
    }

    var windowFrame: NSRect = .zero
    var openSettings: (() -> Void)?
    private var timer: Timer?
    private var mediaTimer: Timer?
    private var systemMonitorTimer: Timer?
    private var collapseTimer: Timer?
    private var isPointerInside = false
    private var isSeeking = false
    private let mediaController = MediaController()
    private let systemMonitorSampler = SystemMonitorSampler()
    private var isPackagedApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    var windowSize: NSSize {
        expandedWindowSize
    }

    var visualSize: NSSize {
        state.isExpanded
            ? expandedVisualSize
            : NSSize(width: max(228, notch.width + 158), height: max(36, notch.topInset + 4))
    }

    var hoverPadding: CGFloat {
        state.isExpanded ? 14 : 3
    }

    private var expandedVisualSize: NSSize {
        NSSize(width: max(540, notch.width + 340), height: systemMonitorEnabled ? 352 : 190)
    }

    private var expandedWindowSize: NSSize {
        NSSize(width: expandedVisualSize.width + 32, height: 386)
    }

    override init() {
        super.init()
        timer = Timer.scheduledTimer(
            timeInterval: 0.14,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        updateSystemMonitorTimer()
    }

    func startMediaUpdates() {
        guard mediaTimer == nil else { return }
        if isPackagedApp {
            let mediaTimer = Timer(
                timeInterval: 2,
                target: self,
                selector: #selector(refreshNowPlaying),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(mediaTimer, forMode: .common)
            self.mediaTimer = mediaTimer
            refreshNowPlaying()
            return
        }

        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            guard let payload = trackInfo?.payload else { return }
            Task { @MainActor in
                self?.apply(payload)
            }
        }
        mediaController.startListening()

        let mediaTimer = Timer(
            timeInterval: 8,
            target: self,
            selector: #selector(refreshNowPlaying),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(mediaTimer, forMode: .common)
        self.mediaTimer = mediaTimer
        refreshNowPlaying()
    }

    @objc private func tick() {
        guard state.isPlaying else { return }
        levels = levels.map { _ in Double.random(in: 0.2...1.0) }
        if !isSeeking, durationSeconds > 0 {
            elapsedSeconds = min(durationSeconds, elapsedSeconds + 0.14)
        }
    }

    private func updateSystemMonitorTimer() {
        systemMonitorTimer?.invalidate()
        systemMonitorTimer = nil
        guard systemMonitorEnabled else { return }

        refreshSystemMonitor()
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(refreshSystemMonitor),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        systemMonitorTimer = timer
    }

    @objc private func refreshSystemMonitor() {
        systemMonitorSnapshot = systemMonitorSampler.sample()
    }

    func setHovered(_ hovered: Bool) {
        if hovered {
            collapseTimer?.invalidate()
            setExpanded(true)
            return
        }

        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(
            timeInterval: 0.28,
            target: self,
            selector: #selector(collapseIfMouseOutside),
            userInfo: nil,
            repeats: false
        )
    }

    func updatePointer(at point: NSPoint) -> Bool {
        let inside = currentVisualFrame.insetBy(dx: -hoverPadding, dy: -hoverPadding).contains(point)
        guard inside != isPointerInside else { return inside }

        isPointerInside = inside
        setHovered(inside)
        return inside
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.isExpanded != expanded else { return }
        let animation = expanded
            ? Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
            : Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

        withAnimation(animation) {
            state.setExpanded(expanded)
        }
    }

    @objc private func collapseIfMouseOutside() {
        guard !currentVisualFrame.insetBy(dx: -hoverPadding, dy: -hoverPadding).contains(NSEvent.mouseLocation) else { return }
        setExpanded(false)
    }

    private var currentVisualFrame: NSRect {
        NSRect(
            x: windowFrame.midX - visualSize.width / 2,
            y: windowFrame.maxY - visualSize.height,
            width: visualSize.width,
            height: visualSize.height
        )
    }

    func togglePlayback() {
        state.togglePlayback()
        sendMediaCommand(["toggle_play_pause"]) {
            mediaController.togglePlayPause()
        }
    }

    func previousTrack() {
        sendMediaCommand(["previous_track"]) {
            mediaController.previousTrack()
        }
    }

    func nextTrack() {
        sendMediaCommand(["next_track"]) {
            mediaController.nextTrack()
        }
    }

    func showSettings() {
        openSettings?()
    }

    func scrub(to fraction: Double, isFinal: Bool) {
        guard durationSeconds > 0 else { return }
        isSeeking = true
        elapsedSeconds = durationSeconds * max(0, min(1, fraction))

        if isFinal {
            sendMediaCommand(["set_time", String(elapsedSeconds)]) {
                mediaController.setTime(seconds: elapsedSeconds)
            }
            isSeeking = false
            refreshNowPlaying()
        }
    }

    @objc private func refreshNowPlaying() {
        if isPackagedApp {
            refreshPackagedNowPlaying()
            return
        }

        mediaController.getTrackInfo { [weak self] trackInfo in
            guard let payload = trackInfo?.payload else { return }
            Task { @MainActor in
                self?.apply(payload)
            }
        }
    }

    private func refreshPackagedNowPlaying() {
        guard let scriptPath = packagedScriptPath, let libraryPath = adapterLibraryPath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, libraryPath, "get"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let output = DataAccumulator()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            output.append(data)
        }

        process.terminationHandler = { [weak self] _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let data = output.snapshot()

            guard
                let line = String(data: data, encoding: .utf8)?
                    .split(separator: "\n", maxSplits: 1)
                    .first,
                let lineData = String(line).data(using: .utf8),
                let trackInfo = try? JSONDecoder().decode(TrackInfo.self, from: lineData)
            else { return }

            Task { @MainActor in
                self?.apply(trackInfo.payload)
            }
        }

        try? process.run()
    }

    private func sendMediaCommand(_ arguments: [String], fallback: () -> Void) {
        guard isPackagedApp, let scriptPath = packagedScriptPath, let libraryPath = adapterLibraryPath else {
            fallback()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, libraryPath] + arguments
        try? process.run()
    }

    private var packagedScriptPath: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL
            .appendingPathComponent("MediaRemoteAdapter_MediaRemoteAdapter.bundle")
            .appendingPathComponent("run.pl")
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private var adapterLibraryPath: String? {
        guard let frameworksURL = Bundle.main.privateFrameworksURL else { return nil }
        let path = frameworksURL.appendingPathComponent("libMediaRemoteAdapter.dylib").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func apply(_ item: TrackInfo.Payload) {
        var nextState = state

        if let title = item.title, !title.isEmpty {
            nextState.title = title
        }

        if let artist = item.artist, !artist.isEmpty {
            nextState.artist = artist
        }

        if let isPlaying = item.isPlaying {
            nextState.isPlaying = isPlaying
        }

        state = nextState

        if let durationMicros = item.durationMicros {
            durationSeconds = max(0, durationMicros / 1_000_000)
        }

        if !isSeeking, let currentElapsedTime = item.currentElapsedTime {
            elapsedSeconds = min(max(0, currentElapsedTime), max(durationSeconds, currentElapsedTime))
        }

        if let artwork = item.artwork {
            self.artwork = artwork
        }
    }
}

struct VisualizerView: View {
    @ObservedObject var model: VisualizerModel
    @Namespace private var islandAnimation

    var body: some View {
        content
        .padding(.leading, model.state.isExpanded ? 36 : 16)
        .padding(.trailing, model.state.isExpanded ? 36 : 18)
        .padding(.top, model.state.isExpanded ? 36 : 3)
        .padding(.bottom, model.state.isExpanded ? (model.systemMonitorEnabled ? 40 : 22) : 3)
        .frame(width: model.visualSize.width, height: model.visualSize.height, alignment: .top)
        .background(
            ZStack {
                Color.black
                LinearGradient(
                    colors: [
                        .white.opacity(model.state.isExpanded ? 0.08 : 0.03),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blendMode(.screen)
            }
        )
        .clipShape(NotchTrayShape(
            topCornerRadius: model.state.isExpanded ? 19 : 6,
            bottomCornerRadius: model.state.isExpanded ? 24 : 14
        ))
        .overlay(
            NotchTrayShape(
                topCornerRadius: model.state.isExpanded ? 19 : 6,
                bottomCornerRadius: model.state.isExpanded ? 24 : 14
            )
                .stroke(.white.opacity(model.state.isExpanded ? 0.06 : 0.03), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if model.state.isExpanded {
                CloseButton {
                    NSApp.terminate(nil)
                }
                .padding(.top, 14)
                .padding(.leading, 34)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.state.isExpanded {
                IconButton(systemName: "gearshape.fill") {
                    model.showSettings()
                }
                .padding(.top, 12)
                .padding(.trailing, 34)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .contentShape(Rectangle())
        .onHover { model.setHovered($0) }
        .frame(width: model.windowSize.width, height: model.windowSize.height, alignment: .top)
        .animation(
            model.state.isExpanded
                ? .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0),
            value: model.state.isExpanded
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.state.isExpanded {
            VStack(alignment: .leading, spacing: model.systemMonitorEnabled ? 22 : 16) {
                expandedPlayer

                if model.systemMonitorEnabled {
                    Divider()
                        .overlay(.white.opacity(0.14))
                    SystemMonitorView(snapshot: model.systemMonitorSnapshot)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        } else {
            HStack(spacing: 0) {
                AlbumArt(size: 22, image: model.artwork)
                    .matchedGeometryEffect(id: "art", in: islandAnimation)
                    .frame(width: 30, alignment: .leading)

                Spacer(minLength: model.notch.width + 44)

                MiniBars(levels: model.levels)
                    .matchedGeometryEffect(id: "bars", in: islandAnimation)
                    .frame(width: 24, height: 12)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        }
    }

    private var expandedPlayer: some View {
        HStack(alignment: .center, spacing: 24) {
            AlbumArt(size: 104, image: model.artwork)
                .matchedGeometryEffect(id: "art", in: islandAnimation)

            VStack(alignment: .leading, spacing: 14) {
                expandedTrackText
                ProgressScrubber(
                    elapsed: model.elapsedSeconds,
                    duration: model.durationSeconds
                ) { fraction, isFinal in
                    model.scrub(to: fraction, isFinal: isFinal)
                }
                .frame(height: 24)

                HStack(alignment: .center, spacing: 28) {
                    expandedControls
                    Spacer(minLength: 8)
                    MiniBars(levels: model.levels)
                        .matchedGeometryEffect(id: "bars", in: islandAnimation)
                        .frame(width: 58, height: 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var expandedTrackText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.state.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(model.state.artist)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedControls: some View {
        HStack(spacing: 26) {
            ControlButton(systemName: "backward.fill") {
                model.previousTrack()
            }
            ControlButton(systemName: model.state.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlayback()
            }
            ControlButton(systemName: "forward.fill") {
                model.nextTrack()
            }
        }
    }
}

struct NotchTrayShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

struct ProgressScrubber: View {
    let elapsed: Double
    let duration: Double
    let onScrub: (Double, Bool) -> Void
    @State private var isDragging = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let progress = duration > 0 ? max(0, min(1, elapsed / duration)) : 0
                let isActive = isHovered || isDragging
                let trackHeight: CGFloat = isActive ? 6 : 4
                let knobSize: CGFloat = isDragging ? 18 : isHovered ? 15 : 11

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(Color(red: 0.23, green: 0.55, blue: 1.0))
                        .frame(width: proxy.size.width * progress, height: trackHeight)
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .offset(x: max(0, proxy.size.width * progress - knobSize / 2))
                        .opacity(duration > 0 ? 1 : 0)
                }
                .frame(height: proxy.size.height)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            onScrub(fraction(for: value.location.x, width: proxy.size.width), false)
                        }
                        .onEnded { value in
                            onScrub(fraction(for: value.location.x, width: proxy.size.width), true)
                            isDragging = false
                        }
                )
                .animation(isDragging ? .interactiveSpring(response: 0.12, dampingFraction: 0.86) : .linear(duration: 0.14), value: progress)
                .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isActive)
            }

            HStack {
                Text(formatTime(elapsed))
                Spacer()
                Text(duration > 0 ? "-\(formatTime(max(0, duration - elapsed)))" : "--:--")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.46))
        }
    }

    private func fraction(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(max(0, min(width, x)) / width)
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct AlbumArt: View {
    let size: CGFloat
    let image: NSImage?

    init(size: CGFloat, image: NSImage? = nil) {
        self.size = size
        self.image = image
    }

    var body: some View {
        art
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    @ViewBuilder
    private var art: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.66, blue: 0.88),
                            Color(red: 0.98, green: 0.44, blue: 0.24),
                            Color(red: 0.08, green: 0.12, blue: 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                )
        }
    }
}

struct MiniBars: View {
    let levels: [Double]

    var body: some View {
        GeometryReader { proxy in
            let barWidth = max(1.5, min(4, proxy.size.width / 10))
            let spacing = max(1, min(4, proxy.size.width / 18))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: barWidth, height: max(2, proxy.size.height * level))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct ControlButton: View {
    let systemName: String
    let action: () -> Void
    @State private var isHovered = false
    @State private var didPress = false

    var body: some View {
        Button {
            didPress = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                didPress = false
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(ControlButtonStyle(isHovered: isHovered, didPress: didPress))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.62), value: isHovered)
        .animation(.spring(response: 0.16, dampingFraction: 0.5), value: didPress)
    }
}

struct ControlButtonStyle: ButtonStyle {
    let isHovered: Bool
    let didPress: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isActive = isHovered || didPress || configuration.isPressed

        configuration.label
            .background(
                Circle()
                    .fill(.white.opacity(isActive ? 0.16 : 0))
                    .scaleEffect(configuration.isPressed ? 0.92 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.82 : didPress ? 1.16 : isHovered ? 1.1 : 1)
            .shadow(color: .white.opacity(isActive ? 0.18 : 0), radius: 8)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct SystemMonitorView: View {
    let snapshot: SystemMonitorSnapshot

    private var metrics: [(String, String, String, Double)] {
        [
            ("cpu", "CPU", snapshot.cpuText, snapshot.cpuUsage / 100),
            ("memorychip", "RAM", snapshot.memoryText, snapshot.memoryUsage),
            ("thermometer.medium", "TEMP", "N/A", 0),
            ("display", "GPU", "N/A", 0),
            ("fan", "FAN", "N/A", 0)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System Monitor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("Live")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 0) {
                ForEach(metrics, id: \.1) { metric in
                    SystemMetricTile(
                        systemName: metric.0,
                        title: metric.1,
                        value: metric.2,
                        progress: metric.3
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

struct SystemMetricTile: View {
    let systemName: String
    let title: String
    let value: String
    let progress: Double

    var body: some View {
        VStack(alignment: .center, spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.36))

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)

            Capsule()
                .fill(.white.opacity(0.14))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color(red: 0.23, green: 0.55, blue: 1.0).opacity(progress > 0 ? 1 : 0))
                        .frame(width: 48 * progress, height: 4)
                }
                .frame(width: 48)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.62))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(isHovered ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .help("Settings")
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isHovered)
    }
}

struct SettingsView: View {
    @ObservedObject var model: VisualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))

            Toggle("Mac resource monitor", isOn: $model.systemMonitorEnabled)
                .toggleStyle(.checkbox)

            Text("CPU, temperature, RAM, GPU and fan speed monitoring.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            Text("More features to come...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 340, height: 190, alignment: .topLeading)
    }
}

struct CloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.36, blue: 0.30))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black.opacity(isHovered ? 0.78 : 0))
            }
            .frame(width: 15, height: 15)
            .scaleEffect(isHovered ? 1.08 : 1)
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isHovered)
    }
}

@main
enum MusicVisualizerApplication {
    @MainActor private static var appDelegate: AppDelegate?

    @MainActor static func main() {
        let delegate = AppDelegate()
        appDelegate = delegate
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
