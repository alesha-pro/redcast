import AppKit
import SwiftUI

/// Fork: a code block's language as a small pill in its own hue, over the block's header strip.
@MainActor
enum ChatCodeBadge {
    static func style(_ label: NSTextField, language: String?) {
        let hue = CodeLanguageHue.hue(for: language)
        label.textColor = NSColor(hue.ink)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = Theme.Radius.glyph * 2
        label.layer?.backgroundColor = hue.tileNSColor.withAlphaComponent(0.16).cgColor
        label.isHidden = (language ?? "").isEmpty
    }

    /// As wide as the name and a little padding, centred in the strip's height.
    static func frame(for label: NSTextField, in strip: CGRect) -> CGRect {
        let text = label.intrinsicContentSize
        let width = min(text.width + Theme.Spacing.md * 2, strip.width)
        let height = min(text.height + Theme.Spacing.xxs * 2, strip.height)
        return CGRect(x: strip.minX, y: strip.minY + (strip.height - height) / 2, width: width, height: height)
    }
}

/// Fork: a finished tool call's glyph, in the colour of what it did: web, files, terminal, MCP.
struct ChatToolGlyph: View {
    let use: ChatToolUse
    /// The row's own font, handed down so a row reads the metrics once.
    let font: Font

    var body: some View {
        let kind = ChatToolKind.of(title: use.title, origin: use.origin)
        Image(systemName: kind.symbol)
            .font(font)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind.hue.color)
    }
}

extension View {
    /// Fork: the reader's own message on a wash of the accent, edged a step deeper; a reply, bare.
    @ViewBuilder func chatBubble(isUser: Bool, radius: CGFloat) -> some View {
        if isUser {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            background(shape.fill(Theme.Colors.chatUserBubble))
                .overlay { shape.strokeBorder(Theme.Colors.chatUserBubbleEdge) }
        } else {
            self
        }
    }

    /// Fork: a message arriving while the chat is open rises in; one already there carries nothing.
    @ViewBuilder func chatArrival(_ isNew: Bool) -> some View {
        if isNew { modifier(ChatArrival()) } else { self }
    }
}

/// Opacity and offset only, so an arrival costs no layout and the tail is measured where it lands.
private struct ChatArrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Theme.Spacing.md)
            .onAppear {
                guard !shown else { return }
                withAnimation(Theme.Motion.settle) { shown = true }
            }
    }
}


/// Fork: the settings sidebar's switches, drawn here so they are the accent on any window.
struct ChatSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatSwitch(configuration: configuration)
    }
}

private struct ChatSwitch: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ToggleStyleConfiguration
    @State private var hovered = false

    var body: some View {
        // A button, so the whole row takes the click, Space and VoiceOver's press, as a checkbox did.
        Button { configuration.isOn.toggle() } label: {
            configuration.label
        }
        .buttonStyle(ChatSwitchButtonStyle(isOn: configuration.isOn, hovered: hovered && isEnabled))
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}

/// Matte, so the track answers the pointer and a press with fills of its own.
private struct ChatSwitchButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let isOn: Bool
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            configuration.label
            Capsule()
                .fill(isOn ? Theme.Colors.accent : Theme.Colors.controlPressed)
                .overlay {
                    if configuration.isPressed {
                        Capsule().fill(Theme.Colors.controlPressed)
                    } else if hovered {
                        Capsule().fill(Theme.Colors.controlSurface)
                    }
                }
                .frame(width: Theme.Size.chatSwitch.width, height: Theme.Size.chatSwitch.height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Theme.Colors.chatSwitchKnob)
                        .shadow(color: Theme.Colors.tooltipShadow, radius: 1, y: 0.5)
                        .padding(Theme.Spacing.xxs)
                }
                .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
                .animation(.snappy(duration: Theme.Duration.hover), value: isOn)
                .animation(Theme.Motion.press, value: configuration.isPressed)
        }
        .contentShape(.rect)
    }
}
