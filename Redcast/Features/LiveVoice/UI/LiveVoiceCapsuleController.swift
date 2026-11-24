import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Observable status and waveform levels shown in the floating Live Voice capsule.
@MainActor
@Observable
final class LiveVoiceDisplayState {
    enum Phase: Equatable {
        case connecting
        case listening
        case userSpeaking
        case thinking
        case speaking
        case muted
        case reconnecting
    }

    var phase: Phase = .connecting
    var levels = [Float](repeating: 0, count: LiveVoiceAudio.spectrumBarCount)
    var agentName: String?
    var screenShared = false
    var activeTool: String?
    var isMuted = false

    var statusLabel: String {
        if let activeTool, !activeTool.isEmpty { return activeTool }
        let base: String =
            switch phase {
            case .connecting: String(localized: "Connecting…")
            case .listening: String(localized: "Listening")
            case .userSpeaking: String(localized: "Listening")
            case .thinking: String(localized: "Thinking…")
            case .speaking: String(localized: "Speaking")
            case .muted: String(localized: "Muted")
            case .reconnecting: String(localized: "Reconnecting…")
            }
        guard let agentName, !agentName.isEmpty else { return base }
        return "\(agentName) · \(base)"
    }
}

private struct LiveVoiceWaveform: View {
    let levels: [Float]
    let processing: Bool
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.dictationWaveGap) {
            ForEach(levels.indices, id: \.self) { index in
                let emphasis =
                    processing
                    ? Double(levels[index])
                    : min(1, Double(min(index, levels.count - 1 - index)) / 3)
                Capsule()
                    .fill(Theme.Colors.textPrimary.opacity(dimmed ? 0.35 : 0.4 + 0.6 * emphasis))
                    .frame(
                        width: Theme.Size.dictationWaveBar,
                        height: dimmed ? 3 : 3 + (processing ? 9 : 25) * CGFloat(levels[index]))
            }
        }
        .animation(.easeOut(duration: 0.06), value: levels)
    }
}

private struct LiveVoiceProcessingWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let progress =
                timeline.date.timeIntervalSince(startedAt)
                .truncatingRemainder(dividingBy: 1.2) / 1.2
            let center = (reduceMotion ? 0.5 : progress) * 28 - 4
            LiveVoiceWaveform(
                levels: (0..<LiveVoiceAudio.spectrumBarCount).map { index in
                    Float(max(0, 1 - abs(Double(index) - center) / 4))
                }, processing: true, dimmed: false)
        }
    }
}

private struct CapsuleIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textPrimary.opacity(hovered ? 1 : 0.8))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(hovered ? Theme.Colors.controlHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

private struct LiveVoiceCapsuleView: View {
    let state: LiveVoiceDisplayState
    let onInterrupt: () -> Void
    let onToggleMute: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            statusChip
            capsuleBar
        }
        .padding(Theme.Spacing.xs)
        .fixedSize()
        .motionScope()
    }

    private var statusChip: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if state.screenShared {
                Image(systemName: "display")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityLabel("Screen shared")
            }
            Text(verbatim: state.statusLabel)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(Theme.Motion.swap, value: state.statusLabel)
        .font(Theme.Typography.bar)
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.xs)
        .glassSurface(.chip, in: .capsule)
    }

    private var capsuleBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if state.phase == .speaking {
                CapsuleIconButton(symbol: "stop.fill", label: "Interrupt reply", action: onInterrupt)
            } else {
                CapsuleIconButton(
                    symbol: state.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: state.isMuted ? "Unmute microphone" : "Mute microphone",
                    action: onToggleMute)
            }
            waveform
                .frame(width: 108, height: Theme.Size.dictationPanel.height)
            CapsuleIconButton(symbol: "xmark", label: "End Live Voice", action: onClose)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: Theme.Size.dictationPanel.height)
        .glassSurface(.chip, in: .capsule, tint: glassTint)
        .animation(Theme.Motion.swap, value: state.phase)
    }

    @ViewBuilder
    private var waveform: some View {
        switch state.phase {
        case .connecting, .thinking, .reconnecting:
            LiveVoiceProcessingWave()
                .accessibilityLabel(Text(verbatim: state.statusLabel))
                .transition(.opacity)
        case .muted:
            LiveVoiceWaveform(
                levels: [Float](repeating: 0, count: LiveVoiceAudio.spectrumBarCount),
                processing: false, dimmed: true
            )
            .accessibilityLabel("Microphone muted")
            .transition(.opacity)
        case .listening, .userSpeaking, .speaking:
            LiveVoiceWaveform(
                levels: state.levels.enumerated().map { index, level in
                    let edge = min(1, Float(min(index, state.levels.count - 1 - index)) / 4)
                    let taper = edge * edge * (3 - 2 * edge)
                    return level * (0.2 + 0.8 * taper)
                }, processing: false, dimmed: false
            )
            .accessibilityLabel(Text(verbatim: state.statusLabel))
            .transition(.opacity)
        }
    }

    private var glassTint: Color? {
        switch state.phase {
        case .listening, .userSpeaking: Theme.Colors.liveGlassTint
        case .speaking: Theme.Colors.progress.opacity(0.28)
        case .connecting, .thinking, .muted, .reconnecting: nil
        }
    }
}

private final class LiveVoiceCapsulePanel: NSPanel, AnimatedPanel {
    var onSpace: (() -> Void)?
    var onClose: (() -> Void)?

    init(content: NSView) {
        let size = content.fittingSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        followMotion()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat {
            switch Int(event.keyCode) {
            case kVK_Escape: onClose?(); return
            case kVK_Space: onSpace?(); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

/// Floating dictation-style capsule for an active Live Voice session; built on show, freed on close.
@MainActor
final class LiveVoiceCapsuleController {
    let state = LiveVoiceDisplayState()
    var onInterrupt: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onClose: (() -> Void)?

    private var panel: LiveVoiceCapsulePanel?

    func show(agentName: String?, screenShared: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        state.phase = .connecting
        state.levels = [Float](repeating: 0, count: LiveVoiceAudio.spectrumBarCount)
        state.agentName = agentName
        state.screenShared = screenShared
        state.activeTool = nil
        state.isMuted = false
        let hosting = NSHostingView(
            rootView: LiveVoiceCapsuleView(
                state: state,
                onInterrupt: { [weak self] in self?.onInterrupt?() },
                onToggleMute: { [weak self] in self?.onToggleMute?() },
                onClose: { [weak self] in self?.onClose?() }))
        hosting.sizingOptions = .intrinsicContentSize
        let panel = LiveVoiceCapsulePanel(content: hosting)
        panel.onSpace = { [weak self] in
            guard let self else { return }
            if self.state.phase == .speaking {
                self.onInterrupt?()
            } else {
                self.onToggleMute?()
            }
        }
        panel.onClose = { [weak self] in self?.onClose?() }
        self.panel = panel
        let size = hosting.fittingSize
        let capsuleCenterOffset = Theme.Size.dictationPanel.height / 2 + Theme.Spacing.xs
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.minY + visible.height * 0.1 - capsuleCenterOffset,
                width: size.width, height: size.height),
            display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
