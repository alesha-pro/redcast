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
            print("usage: chat-memory fixtures <files-dir> | measure <report.tsv> [cycles]")
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
        "NSDateFormatter", "ChatSelectableTextView", "ChatTextViewport", "NSTextStorage", "NSLayoutManager",
        "NSTextTable", "NSImage", "NSBitmapImageRep", "CGImage", "NSHostingView", "NSWindow",
        "CUINamedVectorSVGImage", "CUINamedVectorGlyph", "AIChatState", "MathLayoutEngine"
    ]

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
        guard order.count >= 6 else {
            print("fixture missing: run `chat-memory fixtures` first")
            exit(1)
        }
        var lines = ["cycle\tstep\tfootprint_mb\tfootprint_peak_mb\tmalloc_mb\tmalloc_peak_mb"]
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
        }
        _ = probe.mark()
        await settle(1)
        record(0, "idle")
        var census: [(String, [String: Int])] = []
        let before = HeapCensus.take()
        census.append(("idle", before.counts))
        _ = probe.mark()
        for cycle in 1...cycles {
            core.aiChatCoordinator.openChat(id: order[0])
            core.aiChatCoordinator.showWindow()
            ChatMemoryWindow.park()
            await settle(2.5)
            record(cycle, "open")
            for (index, id) in order.dropFirst().prefix(5).enumerated() {
                core.aiChatCoordinator.openChat(id: id)
                if let early = MemoryDetail.early, cycle == 1 {
                    print(ChatMemoryWindow.layerCensus())
                    await settle(early)
                    MemoryDetail.dump("\(cycle) switch \(index + 1) early", beside: report)
                    print(ChatMemoryWindow.layerCensus())
                }
                await settle(2)
                if cycle == 1 { ChatMemoryWindow.shoot("switch-\(index + 1)") }
                record(cycle, "switch \(index + 1)")
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
            #endif
            ChatMemoryWindow.close()
            await settle(4)
            record(cycle, "closed")
            if cycle == 1 || cycle == cycles {
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
        guard ProcessInfo.processInfo.environment["CHAT_MEMORY_ONSCREEN"] == nil else { return }
        window?.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
    }

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

    /// The reader paging up through the whole open chat, 300 points at a time.
    static func scrollTranscriptToTop() async {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }
        guard let root = window?.contentView,
            let transcript = scrollViews(in: root).max(by: {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
        else { return }
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

// MARK: - The fixture

/// Forty chats, four of them long, in the harness's own Application Support; nothing of the owner's.
@MainActor
enum ChatMemoryFixture {
    static let longTitles = [
        "Refactor the history store", "Design review: chat workspace", "Screenshot triage",
        "Math notes: Fourier series"
    ]

    static let models = [
        "anthropic/claude-sonnet-4.5", "openai/gpt-5", "google/gemini-2.5-pro", "deepseek/deepseek-v3.2",
        "x-ai/grok-4", "qwen/qwen3-coder", "mistralai/mistral-large", "moonshotai/kimi-k2",
        "z-ai/glm-4.6", "minimax/minimax-m2", "meta-llama/llama-4-maverick", "perplexity/sonar-pro"
    ]

    /// Long, short, another long one, short, the math, then the screenshots, which are scrolled through.
    static func switchOrder(in history: ChatHistoryStore) -> [UUID] {
        let byTitle = Dictionary(
            history.conversations.map { ($0.displayTitle, $0.id) }, uniquingKeysWith: { first, _ in first })
        let names = [
            longTitles[0], "Short chat 3", longTitles[1], "Short chat 7", longTitles[3], longTitles[2]
        ]
        return names.compactMap { byTitle[$0] }
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
        let screenshot = png(width: 2960, height: 2000, seed: 1)
        let staged = png(width: 1568, height: 1060, seed: 2)
        let now = Date()
        var ids: [UUID] = []
        for index in 0..<36 {
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
        for (index, title) in longTitles.enumerated() {
            let at = now.addingTimeInterval(-Double(index + 1) * 1_800)
            var session = ChatSession(
                createdAt: at, model: .api(connection: connection.id, model: models[index], effort: nil))
            for turn in 0..<30 {
                let sent = at.addingTimeInterval(Double(turn) * 30)
                var images: [AIImage] = []
                if index == 2, turn % 10 == 3 {
                    images = [AIImage(data: screenshot, mimeType: "image/png")]
                    if turn == 13 { images.append(AIImage(data: staged, mimeType: "image/png")) }
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

    /// Files the replies name, so the Files strip resolves real paths and an image thumbnail.
    private static func writeFiles(into directory: URL) -> [String] {
        var paths: [String] = []
        for name in ["Store.swift", "Schema.sql", "notes.md", "data.json"] {
            let url = directory.appendingPathComponent(name)
            try? Data(String(repeating: "// \(name)\n", count: 200).utf8).write(to: url)
            paths.append(url.path)
        }
        let image = directory.appendingPathComponent("capture.png")
        try? png(width: 2960, height: 2000, seed: 3).write(to: image)
        paths.append(image.path)
        return paths
    }

    /// A screenshot-like picture: noise and bands, so it compresses like a real one, not to nothing.
    static func png(width: Int, height: Int, seed: UInt32) -> Data {
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
