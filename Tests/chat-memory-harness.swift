import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// AI Chat's own window over a fixture history, measured step by step; run by `chat-memory.sh`.
@main
@MainActor
enum ChatMemoryHarness {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("usage: chat-memory fixtures <files-dir> | measure|scroll|panes <report.tsv> [cycles]")
            exit(2)
        }
        AppSettings.pinLanguage()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let mode = arguments[1]
        let target = URL(fileURLWithPath: arguments[2])
        let cycles = arguments.count > 3 ? Int(arguments[3]) ?? 3 : 3
        Task { @MainActor in
            switch mode {
            case "fixtures": ChatMemoryFixture.build(files: target)
            case "panes": await ChatMemoryRun(report: target, cycles: cycles).runPanes()
            case "scroll": await ChatMemoryRun(report: target, cycles: cycles).runScroll()
            default: await ChatMemoryRun(report: target, cycles: cycles).run()
            }
            exit(0)
        }
        app.run()
    }
}

// MARK: - Measuring

/// Footprint and live malloc now, and their highs since the last mark, sampled off the main thread.
final class MemoryProbe: @unchecked Sendable {
    struct Reading {
        let footprint: UInt64
        let footprintPeak: UInt64
        let malloc: Int
        let mallocPeak: Int
    }

    private let lock = NSLock()
    private var footprintPeak: UInt64 = 0
    private var mallocPeak = 0
    private typealias ResetInterval = @convention(c) (Int32) -> Int32
    private let resetInterval: ResetInterval? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "proc_reset_footprint_interval"
    ).map { unsafeBitCast($0, to: ResetInterval.self) }

    func start() {
        let thread = Thread { [self] in
            while true {
                sample()
                usleep(2_000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func sample() {
        let footprint = Self.footprint()
        let malloc = Self.mallocInUse()
        lock.lock()
        footprintPeak = max(footprintPeak, footprint)
        mallocPeak = max(mallocPeak, malloc)
        lock.unlock()
    }

    /// The highs since the previous mark, then a new interval from here.
    func mark() -> Reading {
        let footprint = Self.footprint()
        let malloc = Self.mallocInUse()
        let kernelPeak = Self.intervalPeak()
        lock.lock()
        let reading = Reading(
            footprint: footprint, footprintPeak: max(footprintPeak, footprint, kernelPeak),
            malloc: malloc, mallocPeak: max(mallocPeak, malloc))
        footprintPeak = footprint
        mallocPeak = malloc
        lock.unlock()
        _ = resetInterval?(getpid())
        return reading
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func intervalPeak() -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_interval_max_phys_footprint : 0
    }

    static func mallocInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
}

/// `heap`'s count of the classes this work is about, read from outside the process.
enum HeapCensus {
    static let watched = [
        "SVGAttribute", "SVGPathCommand", "SVGShapeNode", "SVGAttributeMap", "SVGPaint",
        "icu::DecimalFormat", "icu::number::LocalizedNumberFormatter", "NSNumberFormatter",
        "NSDateFormatter", "ChatSelectableTextView", "ChatTextViewport", "ChatCodeHeader", "NSConcreteTextStorage",
        "NSLayoutManager", "NSTextContainer", "NSTextAttachment", "NSTextTable", "NSTextTableBlock",
        "NSConcreteAttributedString", "NSConcreteMutableAttributedString", "NSImage", "NSBitmapImageRep",
        "CGImage", "NSWindow", "CUINamedVectorSVGImage", "CUINamedVectorGlyph", "AIChatState",
        "MathLayoutEngine", "ChatFindState"
    ]

    static var everyStep: Bool { ProcessInfo.processInfo.environment["CHAT_MEMORY_CENSUS"] != nil }

    static func take() -> (counts: [String: Int], top: [String], nonObject: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        process.arguments = [String(getpid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([:], [], "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        var counts: [String: Int] = [:]
        var rows: [(bytes: Int, line: String)] = []
        var nonObject = ""
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let count = Int(fields[0]), let bytes = Int(fields[1]) else { continue }
            let name = fields[3...].prefix {
                $0 != "C" && $0 != "ObjC" && $0 != "Swift" && $0 != "C++" && $0 != "CFType"
            }
            .joined(separator: " ")
            if name == "non-object" { nonObject = "\(count) blocks, \(bytes / 1024) KB" }
            for watched in watched where name == watched || name.hasSuffix("." + watched) {
                counts[watched, default: 0] += count
            }
            rows.append((bytes, line.trimmingCharacters(in: .whitespaces)))
        }
        let top = rows.sorted { $0.bytes > $1.bytes }.prefix(25).map(\.line)
        return (counts, Array(top), nonObject)
    }
}

/// `footprint`'s categories and `heap`'s largest classes at one step, beside the report.
enum MemoryDetail {
    static var isOn: Bool { ProcessInfo.processInfo.environment["CHAT_MEMORY_DETAIL"] != nil }
    /// Seconds after a switch for one more dump, to catch what a step's peak is made of.
    static var early: Double? {
        ProcessInfo.processInfo.environment["CHAT_MEMORY_EARLY"].flatMap(Double.init)
    }

    static func dump(_ label: String, beside report: URL) {
        guard isOn else { return }
        let pid = String(getpid())
        let name = label.replacing(" ", with: "-")
        let base = report.deletingPathExtension().path
        let footprint = run("/usr/bin/footprint", [pid])
        let heap = run("/usr/bin/heap", ["-s", pid]).split(separator: "\n").prefix(90).joined(separator: "\n")
        try? (footprint + "\n\n" + heap).write(
            toFile: "\(base)-\(name).txt", atomically: true, encoding: .utf8)
    }

    /// `CHAT_MEMORY_GRAPH=<step>` saves a memory graph there, for `leaks --trace` on what stayed.
    static func graph(at step: String, beside report: URL) -> Bool {
        guard let wanted = ProcessInfo.processInfo.environment["CHAT_MEMORY_GRAPH"],
            wanted.split(separator: ",").contains(where: { step.hasPrefix($0) })
        else { return false }
        let name = step.replacing(" ", with: "-")
        let file = report.deletingPathExtension().path + "-\(name).memgraph"
        _ = run("/usr/bin/leaks", ["--outputGraph=\(file)", String(getpid())])
        return true
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// The steps the owner took: open, switch five chats, the settings sidebar, close; then again.
@MainActor
struct ChatMemoryRun {
    let report: URL
    let cycles: Int
    private let probe = MemoryProbe()

    init(report: URL, cycles: Int) {
        self.report = report
        self.cycles = cycles
    }

    func run() async {
        probe.start()
        let core = AppCore.shared
        core.aiChatCoordinator.applyEnabled()
        await settle(2)
        let order = ChatMemoryFixture.switchOrder(in: core.chatHistory)
        guard order.count == ChatMemoryFixture.switchTitles.count else {
            print("fixture missing: run `chat-memory fixtures` first")
            exit(1)
        }
        var lines = ["cycle\tstep\tfootprint_mb\tfootprint_peak_mb\tmalloc_mb\tmalloc_peak_mb"]
        var census: [(String, [String: Int])] = []
        func record(_ cycle: Int, _ step: String) {
            let reading = probe.mark()
            let line = [
                "\(cycle)", step, mb(reading.footprint), mb(reading.footprintPeak), mb(reading.malloc),
                mb(reading.mallocPeak)
            ].joined(separator: "\t")
            print(line)
            lines.append(line)
            if cycle <= 1 { MemoryDetail.dump("\(cycle) \(step)", beside: report) }
            if MemoryDetail.isOn { _ = probe.mark() }
            if HeapCensus.everyStep, cycle == cycles {
                census.append((step, HeapCensus.take().counts))
                _ = probe.mark()
            }
            if cycle == cycles, MemoryDetail.graph(at: step, beside: report) { _ = probe.mark() }
        }
        _ = probe.mark()
        await settle(1)
        record(0, "idle")
        let before = HeapCensus.take()
        census.append(("idle", before.counts))
        _ = probe.mark()
        for cycle in 1...cycles {
            core.aiChatCoordinator.openChat(id: order[0])
            core.aiChatCoordinator.showWindow()
            ChatMemoryWindow.park()
            await settle(2.5)
            record(cycle, "open")
            for (index, id) in order.dropFirst().enumerated() {
                // `heap` blocks the main thread, so AppKit's deferred releases get their turn first.
                if HeapCensus.everyStep, cycle == cycles { await settle(2) }
                core.aiChatCoordinator.openChat(id: id)
                if let early = MemoryDetail.early, cycle == 1 {
                    print(ChatMemoryWindow.layerCensus())
                    await settle(early)
                    MemoryDetail.dump("\(cycle) switch \(index + 1) early", beside: report)
                    print(ChatMemoryWindow.layerCensus())
                }
                await settle(2)
                if cycle == 1 { ChatMemoryWindow.shoot("switch-\(index + 1)") }
                record(cycle, "switch \(index + 1) \(ChatMemoryFixture.switchLabels[index + 1])")
            }
            await ChatMemoryWindow.scrollTranscriptToTop()
            record(cycle, "scrolled up")
            #if !CHAT_MEMORY_LEGACY
                core.chatWorkspace.toggleSettingsSidebar?()
                await settle(1.5)
                record(cycle, "settings open")
                core.chatWorkspace.toggleSettingsSidebar?()
                await settle(1.5)
                record(cycle, "settings closed")
                // The sidebar's search reaches message text, as a reader looking for a word would.
                core.chatWorkspace.query = "budget"
                await settle(1.5)
                record(cycle, "searched")
                core.chatWorkspace.query = ""
                await settle(1)
                record(cycle, "search cleared")
            #endif
            ChatMemoryWindow.close()
            await settle(4)
            record(cycle, "closed")
            if cycle == 1 || cycle == cycles, !(HeapCensus.everyStep && cycle == cycles) {
                census.append(("closed \(cycle)", HeapCensus.take().counts))
                _ = probe.mark()
            }
        }
        let after = HeapCensus.take()
        lines.append("")
        lines.append("class\t" + census.map(\.0).joined(separator: "\t"))
        for name in HeapCensus.watched {
            lines.append(name + "\t" + census.map { "\($0.1[name] ?? 0)" }.joined(separator: "\t"))
        }
        lines.append("")
        lines.append("non-object idle: \(before.nonObject); end: \(after.nonObject)")
        lines.append("top classes at the end:")
        lines.append(contentsOf: after.top)
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    /// Settings › Shortcuts and › Backup, then the Extension Store in the palette, opened and closed.
    func runPanes() async {
        probe.start()
        let core = AppCore.shared
        core.settings.extensionsEnabled = true
        await settle(2)
        var lines = ["cycle\tstep\tfootprint_mb\tfootprint_peak_mb\tmalloc_mb\tmalloc_peak_mb"]
        var census: [(String, [String: Int])] = [("idle", HeapCensus.take().counts)]
        _ = probe.mark()
        func record(_ cycle: Int, _ step: String) {
            let reading = probe.mark()
            let line = [
                "\(cycle)", step, mb(reading.footprint), mb(reading.footprintPeak), mb(reading.malloc),
                mb(reading.mallocPeak)
            ].joined(separator: "\t")
            print(line)
            lines.append(line)
        }
        for cycle in 1...cycles {
            core.settingsCoordinator.showSettings(tab: .shortcuts)
            await settle(3)
            record(cycle, "settings shortcuts")
            core.settingsCoordinator.showSettings(tab: .backup)
            await settle(2)
            record(cycle, "settings backup")
            for window in NSApp.windows where window.isVisible { window.close() }
            await settle(3)
            record(cycle, "settings closed")
            census.append(("settings closed \(cycle)", HeapCensus.take().counts))
            _ = probe.mark()
            core.extensionStoreCoordinator.show()
            await settle(8)
            record(cycle, "store open")
            core.paletteCoordinator.hidePalette(restoreFocus: false)
            await settle(3)
            record(cycle, "store closed")
            census.append(("store closed \(cycle)", HeapCensus.take().counts))
            _ = probe.mark()
        }
        lines.append("")
        lines.append("class\t" + census.map(\.0).joined(separator: "\t"))
        for name in HeapCensus.watched {
            lines.append(name + "\t" + census.map { "\($0.1[name] ?? 0)" }.joined(separator: "\t"))
        }
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    /// Steady scrolls down and back up the two tallest chats, `cycles` passes each.
    func runScroll() async {
        let core = AppCore.shared
        core.aiChatCoordinator.applyEnabled()
        await settle(2)
        let byTitle = ChatMemoryFixture.idsByTitle(in: core.chatHistory)
        let chats = ChatMemoryFixture.scrollTitles.compactMap { title in byTitle[title].map { (title, $0) } }
        guard chats.count == ChatMemoryFixture.scrollTitles.count else {
            print("fixture missing: run `chat-memory fixtures` first")
            exit(1)
        }
        var lines = [ChatScrollProbe.Pass.header]
        core.aiChatCoordinator.openChat(id: chats[0].1)
        core.aiChatCoordinator.showWindow()
        ChatMemoryWindow.park()
        await settle(3)
        var previous: NSScrollView?
        for (title, id) in chats {
            core.aiChatCoordinator.openChat(id: id)
            await settle(3)
            // Under load the old transcript can still be in the window; wait for the new one.
            for _ in 0..<40 where ChatMemoryWindow.transcriptScrollView() === previous {
                await settle(0.25)
            }
            print("scroll views: " + ChatMemoryWindow.scrollViewHeights())
            guard let scrollView = ChatMemoryWindow.transcriptScrollView() else { continue }
            previous = scrollView
            for (index, fraction) in [0, 0.25, 0.5, 0.75].enumerated() {
                ChatScrollProbe.jump(scrollView, to: fraction)
                await settle(0.8)
                ChatMemoryWindow.shoot("\(ChatMemoryFixture.scrollTitles.firstIndex(of: title) ?? 0)-\(index)")
            }
            for pass in 1...cycles {
                ChatScrollProbe.jump(scrollView, toTop: true)
                await settle(1.5)
                for down in [true, false] {
                    let result = await ChatScrollProbe(scrollView: scrollView, down: down).run()
                    let line = result.line(chat: title, pass: pass, down: down)
                    print(line)
                    lines.append(line)
                    await settle(1)
                }
            }
        }
        ChatMemoryWindow.close()
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func mb(_ bytes: some BinaryInteger) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

/// The real window, moved off every screen so a run does not cover the desktop.
@MainActor
enum ChatMemoryWindow {
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier == AIChatWindowChrome.windowIdentifier && $0.isVisible }
    }

    static func park() {
        guard let window else { return }
        guard ProcessInfo.processInfo.environment["CHAT_MEMORY_ONSCREEN"] != nil else {
            return window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        }
        // In the screen's corner farthest from the pointer: a hover redraws rows on every frame.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(
            NSPoint(
                x: mouse.x < visible.midX ? visible.maxX - size.width : visible.minX,
                y: mouse.y < visible.midY ? visible.maxY - size.height : visible.minY))
    }

    static var holdsPointer: Bool { window?.frame.contains(NSEvent.mouseLocation) == true }

    /// The layers holding contents, largest first, as bytes their backing would take.
    static func layerCensus() -> String {
        guard let root = window?.contentView?.superview?.layer else { return "no layers" }
        var rows: [(bytes: Double, name: String)] = []
        func walk(_ layer: CALayer, depth: Int) {
            if layer.contents != nil {
                let scale = layer.contentsScale
                let bytes = layer.bounds.width * layer.bounds.height * scale * scale * 4
                let view = layer.delegate as? NSView
                let owner = view.map { String(describing: type(of: $0)) } ?? ""
                let frame = layer.convert(layer.bounds, to: root)
                let visible = view.map { "visible \(Int($0.visibleRect.height))" } ?? ""
                let contents = String(describing: type(of: layer.contents!))
                let size = "\(Int(layer.bounds.width))x\(Int(layer.bounds.height))"
                rows.append(
                    (
                        bytes,
                        "\(type(of: layer)) \(owner) \(size) at y \(Int(frame.minY)) \(visible) \(contents)"
                    ))
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        walk(root, depth: 0)
        let total = rows.reduce(0) { $0 + $1.bytes } / 1_048_576
        let top = rows.sorted { $0.bytes > $1.bytes }.prefix(8)
            .map { String(format: "  %.1f MB ", $0.bytes / 1_048_576) + $0.name }
        return String(format: "layers with contents: %d, %.1f MB\n", rows.count, total)
            + top.joined(separator: "\n")
    }

    /// The tallest scroll view showing in the window, which is the transcript's.
    static func transcriptScrollView() -> NSScrollView? {
        scrollViews().max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    static func scrollViews() -> [NSScrollView] {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }
        guard let root = window?.contentView else { return [] }
        return scrollViews(in: root).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
    }

    static func scrollViewHeights() -> String {
        scrollViews().map { "\(Int($0.documentView?.frame.height ?? 0))" }.joined(separator: ", ")
    }

    /// The reader paging up through the whole open chat, 300 points at a time.
    static func scrollTranscriptToTop() async {
        guard let transcript = transcriptScrollView() else { return }
        let clip = transcript.contentView
        let flipped = transcript.documentView?.isFlipped ?? true
        var delays: [Double] = []
        defer {
            let sorted = delays.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            print(
                String(
                    format: "scroll: %d steps, main thread late by %.0f ms median, %.0f ms worst",
                    sorted.count, median, sorted.last ?? 0))
        }
        for _ in 0..<600 {
            let height = transcript.documentView?.frame.height ?? 0
            let top = flipped ? 0 : max(height - clip.bounds.height, 0)
            guard abs(clip.bounds.minY - top) > 1 else { break }
            let step = flipped ? max(clip.bounds.minY - 300, top) : min(clip.bounds.minY + 300, top)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: step))
            transcript.reflectScrolledClipView(clip)
            let asked = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(40))
            let late = asked.duration(to: .now) - .milliseconds(40)
            delays.append(Double(late.components.attoseconds) / 1e15 + Double(late.components.seconds) * 1000)
        }
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// The window's layers as composited, for `CHAT_MEMORY_SHOTS=<dir>` to check what was drawn.
    static func shoot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["CHAT_MEMORY_SHOTS"],
            let layer = window?.contentView?.superview?.layer
        else { return }
        let scale = layer.contentsScale
        let size = layer.bounds.size
        guard
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func close() {
        window?.close()
    }
}

// MARK: - Scrolling

/// A reader scrolling at a steady speed: a precise wheel event per display frame, timed on main.
@MainActor
final class ChatScrollProbe: NSObject {
    /// Points per second, about a brisk two-finger swipe held steady.
    static let speed: CGFloat = 3000
    /// A frame longer than this missed a 60 Hz refresh; the half millisecond is vsync jitter.
    nonisolated static let budget = 1000.0 / 60 + 0.5

    struct Pass {
        static let header = [
            "chat", "pass", "direction", "mode", "frames", "seconds", "interval_p50_ms", "interval_p95_ms",
            "interval_max_ms", "over_16.7ms", "missed_refreshes", "busy_p50_ms", "busy_p95_ms", "busy_max_ms",
            "cpu_p50_ms", "cpu_p95_ms", "cpu_max_ms", "pointer_frames", "backward_moves",
            "worst_backward_pt", "worst_drift_pt", "height_changes", "height_min_pt", "height_max_pt",
            "distance_pt"
        ].joined(separator: "\t")

        var intervals: [Double] = []
        var refresh = 1000.0 / 60
        var busy: [Double] = []
        /// The main thread's own CPU time per frame, which another process's load cannot inflate.
        var cpu: [Double] = []
        /// Frames with the pointer over the window, whose hovers make them slower.
        var pointerFrames = 0
        var backwards = 0
        var worstBackward: CGFloat = 0
        var worstDrift: CGFloat = 0
        var heightChanges = 0
        var lowest = CGFloat.infinity
        var highest: CGFloat = 0
        var distance: CGFloat = 0
        var wheel = true
        var seconds = 0.0

        func line(chat: String, pass: Int, down: Bool) -> String {
            func percentile(_ values: [Double], _ fraction: Double) -> String {
                let sorted = values.sorted()
                guard !sorted.isEmpty else { return "0" }
                let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
                return String(format: "%.1f", sorted[index])
            }
            return [
                chat, "\(pass)", down ? "down" : "up", wheel ? "wheel" : "clip", "\(intervals.count)",
                String(format: "%.1f", seconds), percentile(intervals, 0.5), percentile(intervals, 0.95),
                percentile(intervals, 1), "\(intervals.count { $0 > ChatScrollProbe.budget })",
                "\(intervals.reduce(0) { $0 + max(0, Int(($1 / refresh).rounded()) - 1) })",
                percentile(busy, 0.5), percentile(busy, 0.95), percentile(busy, 1), percentile(cpu, 0.5),
                percentile(cpu, 0.95), percentile(cpu, 1), "\(pointerFrames)", "\(backwards)",
                String(format: "%.0f", worstBackward), String(format: "%.0f", worstDrift), "\(heightChanges)",
                String(format: "%.0f", lowest), String(format: "%.0f", highest), String(format: "%.0f", distance)
            ].joined(separator: "\t")
        }
    }

    private let scrollView: NSScrollView
    private let down: Bool
    private var pass = Pass()
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var finished: CheckedContinuation<Void, Never>?
    private var started: CFTimeInterval = 0
    private var lastTick: CFTimeInterval?
    private var tickStart: CFTimeInterval?
    private var tickCPU: Double = 0
    private var lastOffset: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private var expected: CGFloat = 0
    private var remainder: CGFloat = 0
    private var stalled = 0

    init(scrollView: NSScrollView, down: Bool) {
        self.scrollView = scrollView
        self.down = down
    }

    /// The offsets the clip view rests at for the top and the end, its insets included.
    private static func range(of scrollView: NSScrollView) -> ClosedRange<CGFloat> {
        let insets = scrollView.contentView.contentInsets
        let height = scrollView.documentView?.frame.height ?? 0
        let top = -insets.top
        return top...max(top, height - scrollView.contentView.bounds.height + insets.bottom)
    }

    static func jump(_ scrollView: NSScrollView, toTop: Bool) {
        jump(scrollView, to: toTop ? 0 : 1)
    }

    /// To a fraction of the way down, rounded to whole points so two trees land alike.
    static func jump(_ scrollView: NSScrollView, to fraction: CGFloat) {
        let range = range(of: scrollView)
        let clip = scrollView.contentView
        let offset = (range.lowerBound + (range.upperBound - range.lowerBound) * fraction).rounded()
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offset))
        scrollView.reflectScrolledClipView(clip)
    }

    func run() async -> Pass {
        guard let screen = scrollView.window?.screen ?? NSScreen.main else { return pass }
        lastOffset = scrollView.contentView.bounds.minY
        expected = lastOffset
        lastHeight = scrollView.documentView?.frame.height ?? 0
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.idle() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        started = CACurrentMediaTime()
        await withCheckedContinuation { continuation in
            finished = continuation
            link.add(to: .main, forMode: .common)
        }
        return pass
    }

    /// After AppKit's and Core Animation's own observers: the frame's layout and commit are done.
    private func idle() {
        guard let tickStart else { return }
        pass.busy.append((CACurrentMediaTime() - tickStart) * 1000)
        pass.cpu.append(Self.threadCPU() - tickCPU)
        self.tickStart = nil
    }

    /// Milliseconds of CPU the calling thread has used, user and system.
    private static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
        return user + Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let clip = scrollView.contentView
        let offset = clip.bounds.minY
        let height = scrollView.documentView?.frame.height ?? 0
        pass.lowest = min(pass.lowest, height)
        pass.highest = max(pass.highest, height)
        if ChatMemoryWindow.holdsPointer { pass.pointerFrames += 1 }
        var elapsed = link.targetTimestamp - link.timestamp
        pass.refresh = elapsed * 1000
        if let lastTick {
            elapsed = now - lastTick
            pass.intervals.append(elapsed * 1000)
            let moved = offset - lastOffset
            if down ? moved < -0.5 : moved > 0.5 {
                pass.backwards += 1
                pass.worstBackward = max(pass.worstBackward, abs(moved))
            }
            pass.worstDrift = max(pass.worstDrift, abs(offset - expected))
            if abs(height - lastHeight) > 0.5 { pass.heightChanges += 1 }
            pass.distance += abs(moved)
            if pass.wheel, pass.intervals.count == 2, abs(moved) < 0.5 { pass.wheel = false }
            stalled = abs(moved) < 0.5 ? stalled + 1 : 0
        }
        lastTick = now
        lastOffset = offset
        lastHeight = height
        let range = Self.range(of: scrollView)
        let target = down ? range.upperBound : range.lowerBound
        guard abs(offset - target) > 1, stalled < 30 else { return finish(now) }
        // Steady in time, as fingers are: a late frame carries the distance it missed.
        let step = Self.speed * CGFloat(min(elapsed, 0.1))
        let wanted = min(step + remainder, abs(target - offset))
        let pixels = wanted.rounded(.down)
        remainder = wanted - pixels
        expected = offset + (down ? pixels : -pixels)
        tickStart = now
        tickCPU = Self.threadCPU()
        if pass.wheel,
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(down ? -pixels : pixels),
                wheel2: 0, wheel3: 0)
        {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let wheel = NSEvent(cgEvent: event) { scrollView.scrollWheel(with: wheel) }
        } else {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: expected))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func finish(_ now: CFTimeInterval) {
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        pass.seconds = now - started
        if ProcessInfo.processInfo.environment["CHAT_MEMORY_DEBUG"] != nil {
            print("end at \(scrollView.contentView.bounds.minY) in \(Self.range(of: scrollView)), "
                + "insets \(scrollView.contentInsets) clip \(scrollView.contentView.contentInsets)")
        }
        finished?.resume()
        finished = nil
    }
}

// MARK: - The fixture

/// A hundred short chats and eight long ones, in the harness's own Application Support only.
@MainActor
enum ChatMemoryFixture {
    static let longTitles = [
        "Refactor the history store", "Design review: chat workspace", "Screenshot triage",
        "Math notes: Fourier series"
    ]
    static let repliesTitle = "Long replies: migration guide"
    static let toolsTitle = "Agent run: workspace refactor"
    static let russianTitle = "Разбор хранилища истории"
    static let shortChats = 100

    static let models = [
        "anthropic/claude-sonnet-4.5", "openai/gpt-5", "google/gemini-2.5-pro", "deepseek/deepseek-v3.2",
        "x-ai/grok-4", "qwen/qwen3-coder", "mistralai/mistral-large", "moonshotai/kimi-k2",
        "z-ai/glm-4.6", "minimax/minimax-m2", "meta-llama/llama-4-maverick", "perplexity/sonar-pro"
    ]

    /// Opened on the first, then switched through the rest; the last is paged up through.
    static let switchTitles = [
        longTitles[0], "Short chat 3", repliesTitle, "Short chat 7", toolsTitle, russianTitle, longTitles[3],
        longTitles[2]
    ]
    static let switchLabels = ["store", "short", "replies", "short", "tools", "russian", "math", "screenshots"]
    /// The tallest two, scrolled through end to end.
    static let scrollTitles = [repliesTitle, toolsTitle]

    static func idsByTitle(in history: ChatHistoryStore) -> [String: UUID] {
        Dictionary(
            history.conversations.map { ($0.displayTitle, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    static func switchOrder(in history: ChatHistoryStore) -> [UUID] {
        let byTitle = idsByTitle(in: history)
        return switchTitles.compactMap { byTitle[$0] }
    }

    static func build(files: URL) {
        let core = AppCore.shared
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let connection = AIConnection(
            name: "Fixture Router", provider: .openRouter, baseURL: "http://127.0.0.1:9/api/v1",
            models: models)
        core.aiSettings.save(connection)
        core.settings.aiEnabled = true
        #if !CHAT_MEMORY_LEGACY
            core.chatWorkspace.prepare()
            core.chatWorkspace.settings.showsInspector = false
        #endif
        core.chatHistory.load()
        let paths = writeFiles(into: files)
        // A minute before today began: every run of a day shows the same times and day headers.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-60)
        var ids: [UUID] = []
        for index in 0..<shortChats {
            let at = now.addingTimeInterval(-Double(index + 5) * 7_200)
            var session = ChatSession(
                createdAt: at,
                model: .api(connection: connection.id, model: models[index % models.count], effort: nil))
            let turns = 1 + index % 3
            for turn in 0..<turns {
                let sent = at.addingTimeInterval(Double(turn) * 60)
                session.append(
                    ChatMessage(role: .user, text: "Short question \(turn) for chat \(index)?", sentAt: sent))
                session.append(
                    ChatMessage(
                        role: .assistant, text: shortReply(index, turn, paths: paths),
                        sentAt: sent.addingTimeInterval(20),
                        usage: AIUsage(
                            inputTokens: 900, outputTokens: 240, contextWindow: 200_000, costUSD: 0.002)))
            }
            core.chatHistory.save(session)
            core.chatHistory.rename(id: session.id, to: "Short chat \(index)")
            ids.append(session.id)
        }
        // Real screenshots: 3456x2234 with text-like noise, 2-4 MB each, no two alike.
        var seed: UInt32 = 10
        func screenshot() -> AIImage {
            seed += 1
            return AIImage(data: png(width: 3456, height: 2234, seed: seed, dense: true), mimeType: "image/png")
        }
        for (index, title) in longTitles.enumerated() {
            let at = now.addingTimeInterval(-Double(index + 1) * 1_800)
            var session = ChatSession(
                createdAt: at, model: .api(connection: connection.id, model: models[index], effort: nil))
            for turn in 0..<30 {
                let sent = at.addingTimeInterval(Double(turn) * 30)
                var images: [AIImage] = []
                if index == 2, turn % 5 == 3 {
                    images = [screenshot()]
                    if turn == 13 { images += [screenshot(), screenshot()] }
                }
                session.append(
                    ChatMessage(
                        role: .user, text: question(turn, long: turn % 7 == 0), sentAt: sent, images: images))
                session.append(
                    longReply(index: index, turn: turn, at: sent.addingTimeInterval(15), paths: paths))
            }
            core.chatHistory.save(session)
            core.chatHistory.rename(id: session.id, to: title)
            ids.append(session.id)
        }
        let rich: [(String, Int, (Int, Date) -> ChatMessage)] = [
            (repliesTitle, 8, { turn, at in hugeReply(turn, at: at, paths: paths) }),
            (toolsTitle, 24, { turn, at in agentReply(turn, at: at, paths: paths) }),
            (russianTitle, 20, { turn, at in russianReply(turn, at: at, paths: paths) })
        ]
        for (index, (title, turns, reply)) in rich.enumerated() {
            let at = now.addingTimeInterval(-Double(index + 5) * 1_800)
            var session = ChatSession(
                createdAt: at, model: .api(connection: connection.id, model: models[index + 4], effort: nil))
            for turn in 0..<turns {
                let sent = at.addingTimeInterval(Double(turn) * 30)
                let text = title == russianTitle ? russianQuestion(turn) : question(turn, long: turn % 5 == 2)
                session.append(ChatMessage(role: .user, text: text, sentAt: sent))
                session.append(reply(turn, sent.addingTimeInterval(15)))
            }
            core.chatHistory.save(session)
            core.chatHistory.rename(id: session.id, to: title)
            ids.append(session.id)
        }
        core.chatHistory.setPinned(true, id: ids[0])
        #if !CHAT_MEMORY_LEGACY
            let workspace = core.chatWorkspace
            let hues: [RaycastHue] = [.blue, .green, .orange, .purple]
            let folders = ["Work", "Home", "Ideas", "Research"].enumerated().compactMap { index, name in
                workspace.createFolder(
                    named: name, hue: hues[index], symbol: ChatFolder.symbols[index], instructions: nil,
                    agentID: nil)
            }
            for (index, id) in ids.enumerated() where index % 3 == 1 {
                workspace.move(id, to: folders[index % folders.count].id)
            }
            workspace.archive(ids[30])
            workspace.archive(ids[31])
        #endif
        print("fixture: \(core.chatHistory.conversations.count) chats")
        for title in switchTitles {
            guard let id = idsByTitle(in: core.chatHistory)[title], let session = core.chatHistory.session(id: id)
            else { continue }
            let lines = session.messages.reduce(0) { $0 + $1.text.count { $0 == "\n" } + 1 }
            let images = session.messages.reduce(0) { $0 + $1.images.count }
            let bytes = session.messages.reduce(0) { $0 + $1.images.reduce(0) { $0 + $1.data.count } }
            let tools = session.messages.reduce(0) { $0 + $1.toolUses.count }
            let thinking = session.messages.reduce(0) { $0 + $1.reasoning.count }
            print(
                "  \(title): \(session.messages.count) messages, \(lines) lines, \(tools) tool rows, "
                    + "\(thinking) reasoning folds, \(images) images (\(bytes / 1_048_576) MB)")
        }
    }

    private static func russianQuestion(_ turn: Int) -> String {
        "Шаг \(turn): как хранилище должно подгружать переписку, чтобы длинный чат оставался лёгким?"
    }

    /// Several thousand lines across eight replies: prose that wraps, lists, code and tables.
    private static func hugeReply(_ turn: Int, at date: Date, paths: [String]) -> ChatMessage {
        var text = "# Part \(turn + 1) of the migration guide\n\n"
        for section in 0..<12 {
            text += "## \(turn + 1).\(section + 1) Moving the \(["store", "index", "cache", "views"][section % 4])\n\n"
            text += (0..<3).map { paragraph in
                "Paragraph \(paragraph) of section \(section): the window keeps every message it shows, and "
                    + "a long reply is laid out once, at its full height, before the first frame. That is "
                    + "why switching to a chat with replies this long costs what it does, and why the cost "
                    + "has to be paid back when the chat is left, not when the app is quit. See `"
                    + paths[(section + paragraph) % paths.count] + "` for the current shape."
            }.joined(separator: "\n\n")
            text += "\n\n" + (0..<8).map { "- Item \($0): **keep** the \($0 % 2 == 0 ? "summary" : "index") hot" }
                .joined(separator: "\n")
            text += "\n\n```swift\n" + swiftCode(turn * 12 + section).split(separator: "\n").prefix(25)
                .joined(separator: "\n") + "\n```\n\n"
            text += "| Field | Type | Kept | Note |\n| --- | --- | :---: | --- |\n"
                + (0..<6).map { "| field\($0) | `String` | \($0 % 2 == 0 ? "yes" : "no") | note \($0) |" }
                .joined(separator: "\n") + "\n\n"
        }
        return ChatMessage(
            role: .assistant, text: text, sentAt: date,
            reasoning: [ChatReasoning(text: thinking(40), textOffset: 0, duration: 12)],
            usage: AIUsage(inputTokens: 30_000, outputTokens: 9_000, contextWindow: 200_000, costUSD: 0.2))
    }

    /// An agent's turn: text between a dozen long calls, diffs, output and three reasoning folds.
    private static func agentReply(_ turn: Int, at date: Date, paths: [String]) -> ChatMessage {
        let chunks = (0..<6).map { chunk in
            "Step \(chunk): checked `\(paths[(turn + chunk) % paths.count])` and "
                + "[the folder](\(paths[paths.count - 1])), then `\(paths[(turn + chunk + 3) % paths.count])`. "
                + "The next calls read the rest; nothing outside the workspace changes.\n\n"
        }
        var text = ""
        var offsets: [Int] = []
        for chunk in chunks {
            offsets.append(text.count)
            text += chunk
        }
        text += "Files touched:\n\n" + paths.dropLast().map { "- `\($0)`" }.joined(separator: "\n")
        let commands = [
            "run_command: rg -n --hidden --glob '!**/node_modules/**' --glob '!**/.build/**' "
                + "'ChatTranscriptView|ChatMarkdownText|ChatSelectableTextView' Tinycast Tests Scripts | head -200",
            "read_file: \(paths[turn % paths.count]) offset=0 limit=4000 encoding=utf-8 follow_symlinks=false",
            "run_command: xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug "
                + "CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/dd build | xcbeautify --quiet",
            "apply_patch: *** Begin Patch *** Update File: Tinycast/Features/AI/UI/ChatTranscriptView.swift @@",
            "search_issues: repo:alesha-pro/redcast is:open label:memory sort:updated-desc chat window"
        ]
        var uses: [ChatToolUse] = []
        for call in 0..<12 {
            let diff = ChatToolContent.Diff(
                path: paths[call % (paths.count - 1)],
                lines: (0..<40).map { ["-", "+", " "][$0 % 3] + "    let value\($0) = compute(\($0), turn: \(turn))" }
                    .joined(separator: "\n"))
            let content =
                call % 3 == 0
                ? ChatToolContent(
                    diffs: call % 2 == 0 ? [diff] : [],
                    output: (0..<60).map { "output line \($0): ok, \($0 * 37) bytes" }.joined(separator: "\n"))
                : nil
            uses.append(
                ChatToolUse(
                    callID: "\(turn)-\(call)", origin: call % 4 == 1 ? "GitHub" : "",
                    title: commands[call % commands.count], state: call == 7 ? .failed : .completed,
                    textOffset: offsets[call / 2], sequence: call, content: content))
        }
        return ChatMessage(
            role: .assistant, text: text, sentAt: date, toolUses: uses,
            reasoning: [0, 2, 4].map { ChatReasoning(text: thinking(25), textOffset: offsets[$0], duration: 4) },
            usage: AIUsage(inputTokens: 60_000, outputTokens: 3_000, contextWindow: 200_000, costUSD: 0.1))
    }

    /// Long Cyrillic prose, which shapes and wraps differently from Latin text.
    private static func russianReply(_ turn: Int, at date: Date, paths: [String]) -> ChatMessage {
        let sentences = [
            "Хранилище держит в памяти только сводки чатов, а полную переписку загружает по запросу.",
            "Когда окно переключается на другой чат, прежний должен отпустить всё, что успел построить.",
            "Длинный ответ раскладывается один раз, на всю высоту, ещё до первого кадра прокрутки.",
            "Поэтому стоимость переключения растёт вместе с длиной ответа, а не с числом сообщений.",
            "Файлы, которые называет ответ, проверяются один раз, после того как он закончен."
        ]
        var text = "## Шаг \(turn + 1): что меняется\n\n"
        for paragraph in 0..<10 {
            text += (0..<5).map { sentences[($0 + paragraph + turn) % sentences.count] }.joined(separator: " ")
            text += paragraph % 3 == 0 ? " Подробнее — в `\(paths[paragraph % paths.count])`.\n\n" : "\n\n"
            if paragraph == 4 {
                text += (0..<6).map { "- Пункт \($0 + 1): **сохранить** порядок и не терять выделение" }
                    .joined(separator: "\n") + "\n\n"
            }
        }
        text += "```swift\n" + swiftCode(turn).split(separator: "\n").prefix(20).joined(separator: "\n") + "\n```\n"
        return ChatMessage(
            role: .assistant, text: text, sentAt: date,
            reasoning: [ChatReasoning(text: thinking(20), textOffset: 0, duration: 5)],
            usage: AIUsage(inputTokens: 8_000, outputTokens: 1_500, contextWindow: 200_000, costUSD: 0.02))
    }

    private static func thinking(_ lines: Int) -> String {
        (0..<lines).map { "Thinking line \($0): weigh the cost of keeping every transcript resident." }
            .joined(separator: "\n")
    }

    private static func question(_ turn: Int, long: Bool) -> String {
        let base = "Turn \(turn): how should the store page its transcripts so a long chat stays light?"
        guard long else { return base }
        return base + "\n\n"
            + (0..<24).map { "Context line \($0): the sidebar lists forty chats, each with a preview." }
            .joined(separator: "\n")
    }

    private static func shortReply(_ index: Int, _ turn: Int, paths: [String]) -> String {
        """
        Here is a **short** answer for chat \(index), turn \(turn), with `inline code` and a [link](https://example.com/\(index)).

        - First point, with $E = mc^2$ inline.
        - Second point, see `\(paths[index % paths.count])`.
        """
    }

    private static func longReply(index: Int, turn: Int, at date: Date, paths: [String]) -> ChatMessage {
        let tableRows = (0..<8).map { "| \($0 + 1) | \(($0 + 3) * 17) MB | \(($0 + 1) * 3) MB | row \($0) |" }
            .joined(separator: "\n")
        var text = """
            ## Step \(turn + 1): what changes

            The history store keeps **summaries** resident and loads a transcript only when asked. \
            This reply walks through the change in detail, with code, a table and the maths behind the \
            budget. See [SQLite's docs](https://sqlite.org/lang_select.html) and \
            [Apple's TextKit guide](https://developer.apple.com/documentation/appkit/textkit).

            1. Read `\(paths[turn % paths.count])` first.
            2. Then compare with `\(paths[(turn + 1) % paths.count])`.
            3. Keep an eye on the budget: $\\sum_{i=1}^{n} b_i \\le B$ where $b_i$ is a message's bytes.

            ```swift
            \(swiftCode(turn))
            ```

            | Step | Before | After | Note |
            | --- | ---: | ---: | --- |
            \(tableRows)

            """
        if index == 3 || turn % 5 == 0 {
            text += """

                The series converges where the function is smooth:

                $$f(x) = \\frac{a_0}{2} + \\sum_{n=1}^{\\infty} \\left(a_n \\cos\\frac{2\\pi n x}{P}\\right)$$

                and the coefficients are $a_n = \\frac{2}{P}\\int_{0}^{P} f(x) \\cos\\frac{2\\pi n x}{P}\\,dx$.

                $$\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}$$

                """
        }
        if turn % 3 == 0 {
            text += """

                ```json
                \(jsonBlock(turn))
                ```

                > A quoted note: the window should never hold more than the screen shows.

                """
        }
        text += "\nThat is the whole step; the next one builds on it."
        let thinking = (0..<30).map {
            "Thinking line \($0): weigh the cost of keeping every transcript resident."
        }
        .joined(separator: "\n")
        return ChatMessage(
            role: .assistant, text: text, sentAt: date,
            searches: turn % 4 == 0
                ? [
                    ChatSearch(
                        query: "sqlite paging transcripts", isComplete: true, textOffset: 0, sequence: 0)
                ] : [],
            toolUses: [
                ChatToolUse(
                    callID: "\(turn)-a", origin: "", title: "read_file: \(paths[0])", state: .completed,
                    textOffset: 0, sequence: 1),
                ChatToolUse(
                    callID: "\(turn)-b", origin: "GitHub", title: "search_issues", state: .completed,
                    textOffset: 0, sequence: 2),
                ChatToolUse(
                    callID: "\(turn)-c", origin: "", title: "run_command: swift build", state: .completed,
                    textOffset: 120, sequence: 3)
            ],
            reasoning: [ChatReasoning(text: thinking, textOffset: 0, duration: 6)],
            usage: AIUsage(
                inputTokens: 12_000 + turn * 400, outputTokens: 1_800, cachedInputTokens: 8_000,
                reasoningTokens: 400, contextWindow: 200_000, costUSD: 0.03))
    }

    private static func swiftCode(_ seed: Int) -> String {
        (0..<70).map { line in
            switch line % 7 {
            case 0: "/// Line \(line) of block \(seed): a store that pages its transcripts."
            case 1: "final class TranscriptPage\(line) {"
            case 2: "    private var messages: [ChatMessage] = []"
            case 3: "    func load(_ id: UUID, limit: Int = \(line * 10)) async throws -> [ChatMessage] {"
            case 4: "        let rows = try await database.rows(\"SELECT * FROM messages WHERE id = ?\", id)"
            case 5: "        return rows.map(ChatMessage.init).filter { $0.text.count > \(line) }"
            default: "    }\n}"
            }
        }.joined(separator: "\n")
    }

    private static func jsonBlock(_ seed: Int) -> String {
        "{\n"
            + (0..<30).map {
                "  \"key\($0)\": { \"seed\": \(seed), \"value\": \"\(String(repeating: "x", count: $0 % 20))\" }"
            }
            .joined(separator: ",\n") + "\n}"
    }

    /// Files the replies name, for the Files strip's thumbnails and icons; a folder last.
    private static func writeFiles(into directory: URL) -> [String] {
        var paths: [String] = []
        let names = [
            "Store.swift", "Schema.sql", "notes.md", "data.json", "Layout.swift", "Index.swift", "Cache.swift",
            "report.pdf", "build.sh"
        ]
        for name in names {
            let url = directory.appendingPathComponent(name)
            try? Data(String(repeating: "// \(name)\n", count: 200).utf8).write(to: url)
            paths.append(url.path)
        }
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("build.sh").path)
        for (index, name) in ["capture.png", "diagram.png"].enumerated() {
            let image = directory.appendingPathComponent(name)
            try? png(width: 2960, height: 2000, seed: UInt32(3 + index)).write(to: image)
            paths.append(image.path)
        }
        let folder = directory.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        paths.append(folder.path)
        return paths
    }

    /// A screenshot-like picture: noise and bands, so it compresses like a real one, not to nothing.
    static func png(width: Int, height: Int, seed: UInt32, dense: Bool = false) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        var state = seed &* 2_654_435_761
        func next() -> CGFloat {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return CGFloat(state % 1000) / 1000
        }
        for band in 0..<40 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            context.fill(CGRect(x: 0, y: band * height / 40, width: width, height: height / 40 + 1))
        }
        for _ in 0..<4_000 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            context.fill(
                CGRect(
                    x: next() * CGFloat(width), y: next() * CGFloat(height), width: next() * 60,
                    height: next() * 14))
        }
        // A real screenshot's text and photos: one row in eight is noise, so the file is MBs.
        if dense, let pixels = context.data?.assumingMemoryBound(to: UInt32.self) {
            let stride = context.bytesPerRow / 4
            for row in Swift.stride(from: 0, to: height, by: 8) {
                for column in 0..<width {
                    state ^= state << 13
                    state ^= state >> 17
                    state ^= state << 5
                    pixels[row * stride + column] = state | 0xFF00_0000
                }
            }
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
