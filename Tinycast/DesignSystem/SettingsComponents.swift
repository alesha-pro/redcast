import AppKit
import SwiftUI

// The few pieces more than one Settings pane or editor needs; everything else stays feature-owned.

struct SettingsFeatureToggleLabel: View {
    let anchor: SettingsAnchor
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    var body: some View {
        SettingsPaneHero(tab: anchor.tab, subtitle: subtitle) {
            // Fork: the pane's name, as on every hero; the switch keeps its sentence for VoiceOver.
            SettingsRowTitle(anchor, title, shown: anchor.tab.title)
                .accessibilityLabel(Text(title))
        }
    }
}

/// Fork: what every pane opens on: its tile, a name and one line saying what the pane is for.
struct SettingsPaneHero<Title: View>: View {
    let tab: SettingsTab
    let subtitle: LocalizedStringResource
    @ViewBuilder var title: Title

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            SettingsTabTile(tab: tab, size: Theme.Size.settingsPaneHeroTile)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                title.font(Theme.Typography.paneHeroTitle)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

/// Fork: the hero of a pane with no master switch, as the first section of its `Form`.
struct SettingsPaneHeader: View {
    let tab: SettingsTab
    let subtitle: LocalizedStringResource

    var body: some View {
        Section {
            SettingsPaneHero(tab: tab, subtitle: subtitle) { Text(tab.title) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Fork: a state in a word, on a wash of its own hue; the glyph repeats it for a glance.
struct SettingsStatusBadge: View {
    enum Tone {
        case success, warning, neutral

        fileprivate var ink: Color {
            switch self {
            case .success: Theme.Colors.successInk
            case .warning: Theme.Colors.warningInk
            case .neutral: Theme.Colors.textSecondary
            }
        }

        fileprivate var wash: Color {
            switch self {
            case .success: Theme.Colors.success.opacity(Theme.Opacity.badgeFill)
            case .warning: Theme.Colors.warning.opacity(Theme.Opacity.badgeFill)
            case .neutral: Theme.Colors.controlSurface
            }
        }
    }

    let title: String
    var symbol: String?
    let tone: Tone

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let symbol {
                Image(systemName: symbol).accessibilityHidden(true)
            }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.ink)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs - 1)
        .background(tone.wash, in: Capsule())
        .fixedSize()
    }
}

/// Not `LabeledContent`: its selectable text field eats the taps a `ShortcutRecorder` needs.
struct SettingsRow<Icon: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleLineLimit = 1
    var alignment: VerticalAlignment = .center
    var labelOpacity = 1.0
    /// Set when a search result points at this row, so its title can carry the pulse.
    var anchor: SettingsAnchor?
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: alignment, spacing: Theme.Spacing.lg) {
            icon.opacity(labelOpacity)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Group {
                    if let anchor {
                        SettingsRowTitle(anchor, verbatim: title)
                    } else {
                        Text(title)
                    }
                }
                .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
            }
            .opacity(labelOpacity)
            Spacer(minLength: Theme.Spacing.lg)
            trailing
        }
    }
}

enum SettingsListMetrics {
    static let iconSize = Theme.Size.settingsRowIcon + Theme.Spacing.xs
}

extension SettingsRow where Icon == EmptyView {
    init(
        title: String, subtitle: String? = nil, subtitleLineLimit: Int = 1,
        alignment: VerticalAlignment = .center, labelOpacity: Double = 1,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title, subtitle: subtitle, subtitleLineLimit: subtitleLineLimit,
            alignment: alignment, labelOpacity: labelOpacity, icon: { EmptyView() },
            trailing: trailing)
    }

    /// A fixed row a search result lands on, so its title is always Tinycast's own text.
    init(
        title: LocalizedStringResource, subtitle: String? = nil, subtitleLineLimit: Int = 1,
        alignment: VerticalAlignment = .center, anchor: SettingsAnchor,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title.resolved(), subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit, alignment: alignment, anchor: anchor,
            icon: { EmptyView() }, trailing: trailing)
    }
}

struct SettingsScopeRow: View {
    let scope: String
    let path: String
    let isMissing: Bool
    let onRemove: () -> Void

    private var isFolder: Bool { (path as NSString).pathExtension != "app" }

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.sm) {
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warning)
                        .help("This location no longer exists.")
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .settingsControl(.glyph)
                .accessibilityLabel("Remove \(scope)")
            }
        } label: {
            HStack {
                Image(nsImage: IconCache.icon(forFile: path))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .id(IconCache.style.generation)
                    .frame(
                        width: SettingsListMetrics.iconSize
                            - (isFolder ? Theme.Spacing.xxs + 1 : 0),
                        height: SettingsListMetrics.iconSize - (isFolder ? 1 : 0)
                    )
                    .frame(
                        width: SettingsListMetrics.iconSize,
                        height: SettingsListMetrics.iconSize
                    )
                    .accessibilityHidden(true)
                Text(scope)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
        }
    }
}

/// Fork: the custom Settings controls that answer hover, press and keyboard focus alike.
enum SettingsControlKind {
    /// One square option in a row of them: Interface Size, Emoji Skin Tone.
    case segment(isSelected: Bool)
    /// A glyph at a row's trailing edge, on one square tile whatever the glyph's own shape.
    case rowIcon
    /// A circle glyph that clears or removes: its ink steps up, as a tile would double its shape.
    case glyph
    /// A row in a picker panel, or with `isCell` one tile of a picker's grid.
    case pickerRow(isSelected: Bool, isCell: Bool = false)
}

private struct SettingsControlStyle: ButtonStyle {
    let kind: SettingsControlKind
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        ControlBody(kind: kind, isFocused: isFocused, configuration: configuration)
    }

    private struct ControlBody: View {
        let kind: SettingsControlKind
        let isFocused: Bool
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            label
                .frame(width: side, height: side)
                .frame(minWidth: minimumWidth)
                .background { shape.fill(fill).frame(minWidth: tile, minHeight: tile) }
                .overlay {
                    if isFocused {
                        shape.strokeBorder(Theme.Colors.focusRing, lineWidth: 2)
                            .frame(minWidth: tile, minHeight: tile)
                            .padding(-ringOutset)
                    }
                }
                .contentShape(SettingsControlArea(tile: tile ?? 0))
                .onHover { hovered = $0 }
                .animation(Theme.Motion.hover, value: hovered)
                .animation(Theme.Motion.press, value: configuration.isPressed)
        }

        @ViewBuilder private var label: some View {
            if case .glyph = kind {
                configuration.label.foregroundStyle(glyphInk)
            } else {
                configuration.label
            }
        }

        private var side: CGFloat? {
            if case .segment = kind { Theme.Size.settingsControlHeight } else { nil }
        }

        /// A row icon's square, centred on its glyph and drawn past it so the row keeps its height.
        private var tile: CGFloat? {
            if case .rowIcon = kind { Theme.Size.settingsRowIconTile } else { nil }
        }

        /// Wide enough that two tiles across a row's `lg` gap never overlap.
        private var minimumWidth: CGFloat? {
            tile.map { $0 - Theme.Spacing.lg }
        }

        /// A bare glyph's ring stands off it; drawn on its bounds it would repaint the glyph's rim.
        private var ringOutset: CGFloat {
            if case .glyph = kind { Theme.Spacing.xxs } else { 0 }
        }

        private var radius: CGFloat {
            switch kind {
            case .segment: Theme.Radius.barControl
            case .rowIcon: Theme.Radius.menu
            case .glyph: Theme.Size.settingsRowIconTile / 2
            case .pickerRow(_, let isCell): isCell ? Theme.Radius.menu : Theme.Radius.menuRow
            }
        }

        private var glyphInk: HierarchicalShapeStyle {
            if configuration.isPressed { return .primary }
            return hovered ? .secondary : .tertiary
        }

        private var fill: Color {
            switch kind {
            case .segment(let isSelected):
                if configuration.isPressed { return Theme.Colors.controlHover }
                if isSelected { return Theme.Colors.controlSurface }
                return hovered ? Theme.Colors.rowHover : .clear
            case .rowIcon:
                if configuration.isPressed { return Theme.Colors.controlPressed }
                return hovered ? Theme.Colors.controlSurface : .clear
            case .glyph:
                return .clear
            case .pickerRow(let isSelected, _):
                if configuration.isPressed { return Theme.Colors.controlHover }
                if isSelected { return Theme.Colors.selection }
                return hovered ? Theme.Colors.menuHover : .clear
            }
        }
    }
}

/// A control's own bounds, grown to the tile a row icon draws around its glyph.
private struct SettingsControlArea: Shape {
    let tile: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            rect.insetBy(
                dx: min(0, (rect.width - tile) / 2), dy: min(0, (rect.height - tile) / 2)))
    }
}

/// Holds the focus the style paints: the ring is Tinycast's, so the system's is switched off.
private struct SettingsControl: ViewModifier {
    let kind: SettingsControlKind
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(SettingsControlStyle(kind: kind, isFocused: isFocused))
            .focused($isFocused)
            .focusEffectDisabled()
    }
}

extension View {
    /// On the `Button`, not its label, so the style can answer its press and its focus.
    func settingsControl(_ kind: SettingsControlKind) -> some View {
        modifier(SettingsControl(kind: kind))
    }

    /// Dims as well as disables; `.disabled` alone leaves the title at full strength.
    func settingsEnabled(_ isEnabled: Bool) -> some View {
        disabled(!isEnabled).opacity(isEnabled ? 1 : Theme.Opacity.disabled)
    }

    func settingsEditorTextField() -> some View {
        modifier(SettingsEditorTextField())
    }

    func settingsEditorTextArea(height: CGFloat) -> some View {
        modifier(SettingsEditorTextArea(height: height))
    }

    /// `controlsOnGlass: false` draws the glass behind, so a control keeps its accent colour.
    func settingsEditorPanelSurface(controlsOnGlass: Bool = true) -> some View {
        modifier(SettingsEditorPanelSurface(controlsOnGlass: controlsOnGlass))
    }

    /// An alias field's and a recorder's edge: lifted under the pointer, a focus ring while live.
    func inlineControlEdge(
        _ shape: RoundedRectangle, isActive: Bool, isHovered: Bool
    ) -> some View {
        overlay {
            shape.strokeBorder(
                isActive
                    ? Theme.Colors.focusRing : isHovered ? Theme.Colors.border : Theme.Colors.cardStroke,
                lineWidth: isActive ? 2 : Theme.Size.hairline
            )
            .allowsHitTesting(false)
            .animation(Theme.Motion.hover, value: isHovered)
        }
    }

    /// The one place that says hiding a row from the launcher never unbinds its shortcut.
    func launcherVisibilityHelp() -> some View {
        help("Show in launcher. Its shortcut works either way.")
    }
}

struct SettingsEditorHeader: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.panelTitle)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsEditorField<Content: View>: View {
    let title: LocalizedStringResource
    var labelFont: Font?
    @ViewBuilder var content: Content

    init(
        _ title: LocalizedStringResource, labelFont: Font? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.labelFont = labelFont
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            Text(title).font(labelFont)
        }
    }
}

private struct SettingsEditorTextField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: Theme.Size.dialogButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.Colors.controlSurface))
    }
}

private struct SettingsEditorTextArea: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(Theme.Spacing.sm)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.Colors.controlSurface))
    }
}

extension EnvironmentValues {
    /// Fork: set by the presenter: a picker takes the menu's corner, an editor the panel's.
    @Entry var settingsPanelRadius = Theme.Radius.panel
}

private struct SettingsEditorPanelSurface: ViewModifier {
    let controlsOnGlass: Bool
    @Environment(\.settingsPanelRadius) private var radius

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // In front of the glass: a glass fill is hit-testable and would hide a handle behind it.
        let draggable = content.background(WindowDragBackground())
        if controlsOnGlass {
            draggable.glassSurface(.modal, in: shape)
        } else {
            draggable.background { Color.clear.glassSurface(.modal, in: shape) }
        }
    }
}

struct FeatureSwitchSection: View {
    let anchor: SettingsAnchor
    let enableTitle: LocalizedStringResource
    var enableSubtitle: LocalizedStringResource?
    @Binding var isEnabled: Bool
    @Binding var showsInLauncher: Bool
    var showsIcon = false
    var showsHeader = true

    var body: some View {
        if showsHeader {
            section
        } else {
            section.settingsAnchor(anchor)
        }
    }

    private var section: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                if showsIcon, let enableSubtitle {
                    SettingsFeatureToggleLabel(
                        anchor: anchor, title: enableTitle, subtitle: enableSubtitle)
                } else {
                    SettingsRowTitle(anchor, enableTitle)
                    if let enableSubtitle { Text(enableSubtitle) }
                }
            }
            Toggle("Show in launcher", isOn: $showsInLauncher)
                // The switch above stays live so the feature can always be turned back on.
                .settingsEnabled(isEnabled)
        } header: {
            if showsHeader { SettingsSectionHeader(anchor) }
        }
    }
}

/// The filter row above a long list, shaped like a search field rather than a form text field.
struct SettingsFilterField: View {
    let prompt: LocalizedStringResource
    @Binding var query: String
    /// The plain field has no bezel: without this only the glyphs are a target.
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // `prompt:` + `labelsHidden`, or the form makes the placeholder a left-column heading.
            TextField("", text: $query, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .pointerStyle(.horizontalText)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .settingsControl(.glyph)
                .accessibilityLabel("Clear search")
            }
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
    }
}

private struct AliasTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let onCancel: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let editor = NSTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editor.textContainerInset = NSSize(width: 0, height: 5.5)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.maximumNumberOfLines = 1
        editor.textContainer?.lineBreakMode = .byTruncatingTail
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.setAccessibilityRole(.textField)
        return editor
    }

    func updateNSView(_ editor: NSTextView, context: Context) {
        context.coordinator.field = self
        if editor.string != text { editor.string = text }
        editor.isEditable = isEnabled
        editor.isSelectable = isEnabled
        editor.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        if !focused, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var field: AliasTextField

        init(_ field: AliasTextField) {
            self.field = field
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            field.text = editor.string
        }

        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString, replacementString.contains(where: \.isNewline) else {
                return true
            }
            textView.insertText(
                String(replacementString.map { $0.isNewline ? " " : $0 }),
                replacementRange: range)
            return false
        }

        func textDidBeginEditing(_ notification: Notification) {
            field.focused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            field.focused = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                textView.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.recalculateKeyViewLoop()
                textView.window?.selectNextKeyView(textView)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.recalculateKeyViewLoop()
                textView.window?.selectPreviousKeyView(textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.onCancel()
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// Dressed like `ShortcutRecorder`; the persistent AppKit field preserves focus across updates.
struct AliasField: View {
    /// The owner's `preferenceKey`, taken raw so a row without an `AppEntry` can carry one too.
    let key: String
    let name: String
    @Environment(AliasStore.self) private var aliases
    @State private var draft = ""
    @State private var focused = false
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        HStack(spacing: Theme.Spacing.xs) {
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text("Add Alias")
                        .font(Theme.Typography.keyCap)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                AliasTextField(text: $draft, focused: $focused, onCancel: revert)
                    .focusEffectDisabled()
                    // The pane's `releasesFocusOnOutsideClick` resigns; this catches it landing.
                    .onChange(of: focused) { _, now in
                        if !now { commit() }
                    }
            }
            if !draft.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.inlineClear)
                }
                .settingsControl(.glyph)
                .accessibilityLabel("Clear alias for \(name)")
            }
        }
        .onAppear { draft = aliases.alias(for: key) ?? "" }
        // A backup import replaces the table out from under an unfocused row.
        .onChange(of: aliases.revision) { _, _ in
            if !focused { draft = aliases.alias(for: key) ?? "" }
        }
        // A reused table row hands the field another entry; unsaved text belongs to the old one.
        .onChange(of: key) { old, new in
            if focused {
                aliases.setAlias(draft, for: old)
                focused = false
            }
            draft = aliases.alias(for: new) ?? ""
        }
        .padding(.horizontal, Theme.Spacing.sm + 1)
        .frame(width: Theme.Size.shortcutRecorder, height: Theme.Size.settingsInlineControl)
        .background(shape.fill(Theme.Colors.cardFill))
        .inlineControlEdge(shape, isActive: focused, isHovered: hovered)
        .clipShape(shape)
        .onHover { hovered = $0 }
        .accessibilityLabel("Alias for \(name)")
    }

    /// The one commit path — ↵ or focus landing elsewhere; a blank draft removes the alias.
    private func commit() {
        aliases.setAlias(draft, for: key)
        draft = aliases.alias(for: key) ?? ""
    }

    private func revert() {
        draft = aliases.alias(for: key) ?? ""
        focused = false
    }

    private func clear() {
        draft = ""
        commit()
    }
}

extension AliasField {
    init(entry: AppEntry) {
        self.init(key: entry.preferenceKey, name: entry.name)
    }
}
