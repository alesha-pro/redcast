import SwiftUI

/// Fork: the chat's settings on the right, as Raycast's: everything the composer used to hold.
struct ChatSettingsSidebar: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace

    var body: some View {
        let chat = workspace.chats.window
        VStack(spacing: 0) {
            if let state = workspace.settingsSource?.settingsState(for: chat) {
                ChatSettingsContent(state: state)
                    .id(state.chatID)
            }
        }
        // An ideal size of its own: a hosting controller reports a bare scroll view as zero.
        .frame(
            minWidth: Theme.Size.chatSettingsMinimum, idealWidth: Theme.Size.chatSettingsMinimum,
            maxWidth: .infinity, minHeight: Theme.Size.chatSettingsMinimum,
            idealHeight: Theme.Size.aiChatWindow.height, maxHeight: .infinity, alignment: .top)
    }
}

private struct ChatSettingsContent: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let state: ChatSettingsState
    @State private var title = ""
    @State private var instructions = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                card {
                    field("Title") {
                        TextField(
                            "Title", text: $title, prompt: Text(verbatim: state.placeholderTitle)
                        )
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Theme.Spacing.md)
                        .frame(height: Theme.Size.settingsControlHeight)
                        .background(fieldFill)
                        .focused($titleFocused)
                        .onSubmit { state.rename(title) }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused, title != state.title { state.rename(title) }
                        }
                        .disabled(!state.isSaved)
                        .help(state.isSaved ? "" : "A chat can be named once its first message is sent")
                    }
                    if let agent = state.agent { menuField(agent) }
                    ForEach(state.pickers) { menuField($0) }
                    creativityField
                    folderField
                }
                card {
                    field("Additional Instructions") {
                        ChatInstructionsField(
                            text: $instructions, prompt: "Pass additional instructions for the current chat.")
                        Text("Sent with every message in this chat, after the folder's instructions.")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                toolsCard
                ChatUsageCard(usage: state.usage)
            }
            .padding(Theme.Spacing.xl)
        }
        .scrollIndicators(.never)
        .onAppear {
            title = state.isSaved ? state.title : ""
            instructions = state.instructions
        }
        .onChange(of: state.title) { _, new in if !titleFocused { title = new } }
        .onChange(of: instructions) { _, new in workspace.setInstructions(new, of: state.chatID) }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "slider.horizontal.3")
                .font(.body.weight(.semibold))
                .foregroundStyle(RaycastHue.red.color)
            Text("Chat Settings").font(.headline)
            Spacer(minLength: 0)
            Button {
                workspace.toggleSettingsSidebar?()
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: Theme.Size.settingsControlHeight, height: Theme.Size.settingsControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide Chat Settings  ⇧⌘I")
            .accessibilityLabel("Hide Chat Settings")
        }
    }

    private var creativityField: some View {
        let current = state.creativity
        let menu = ChatSettingsMenu(
            id: "creativity", label: String(localized: "Creativity"),
            title: current?.title ?? String(localized: "creativity-default", defaultValue: "Model Default"),
            icon: .symbol("sparkles", .purple),
            groups: [
                .init(id: "default", choices: [
                    .init(
                        id: "default",
                        title: String(localized: "creativity-default", defaultValue: "Model Default"),
                        isOn: current == nil, select: { workspace.setCreativity(nil, of: state.chatID) })
                ]),
                .init(
                    id: "levels",
                    choices: ChatCreativity.allCases.map { level in
                        .init(
                            id: level.rawValue, title: level.title, isOn: current == level,
                            select: { workspace.setCreativity(level, of: state.chatID) })
                    })
            ],
            isEnabled: state.creativityApplies,
            help: state.creativityApplies
                ? String(localized: "How freely the model words its answers")
                : String(localized: "Only API models take a creativity setting"))
        return menuField(menu)
    }

    private var folderField: some View {
        let folders = workspace.workspace.folders
        let current = workspace.folder(of: state.chatID)
        var choices: [ChatSettingsMenu.Choice] = [
            .init(
                id: "recent", title: String(localized: "Recent"), icon: .symbol("clock", nil),
                isOn: current == nil, select: { workspace.move(state.chatID, to: nil) })
        ]
        choices += folders.map { folder in
            .init(
                id: folder.id.uuidString, title: folder.name, icon: .tile(folder.symbol, folder.hue),
                isOn: current?.id == folder.id, select: { workspace.move(state.chatID, to: folder.id) })
        }
        let menu = ChatSettingsMenu(
            id: "folder", label: String(localized: "Folder"),
            title: current?.name ?? String(localized: "Recent"),
            icon: current.map { .tile($0.symbol, $0.hue) } ?? .symbol("clock", nil),
            groups: [.init(id: "folders", choices: choices)])
        return menuField(menu)
    }

    @ViewBuilder private var toolsCard: some View {
        if state.webSearch != nil || state.tools != nil {
            card {
                Text("Tools")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                if let webSearch = state.webSearch {
                    Toggle(isOn: Binding(get: { webSearch }, set: { state.setWebSearch($0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text("Web Search")
                                Text("For every chat on API models and Codex")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: {
                            ChatSettingsIconView(icon: .symbol("globe", .blue))
                        }
                    }
                    .toggleStyle(ChatSwitchStyle())
                }
                if let tools = state.tools { ChatToolsSection(tools: tools) }
            }
        }
    }

    private func menuField(_ menu: ChatSettingsMenu) -> some View {
        field(verbatim: menu.label) { ChatSettingsDropdown(menu: menu) }
    }

    private var fieldFill: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
            .fill(Theme.Colors.controlSurface)
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) { content() }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Colors.chatSettingsCard))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Colors.cardStroke))
    }

    private func field(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            content()
        }
    }

    private func field(verbatim: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(verbatim: verbatim)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            content()
        }
    }
}

/// A full-width dropdown: the choice's mark, its name, and the menu of every other one.
struct ChatSettingsDropdown: View {
    let menu: ChatSettingsMenu
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(menu.groups) { group in
                Section {
                    ForEach(group.choices) { choice in
                        Toggle(isOn: Binding(get: { choice.isOn }, set: { if $0 { choice.select() } })) {
                            Label {
                                Text(verbatim: choice.title)
                                if let detail = choice.detail { Text(verbatim: detail) }
                            } icon: {
                                if let icon = choice.icon { Image(nsImage: ChatSettingsIconImage.make(icon)) }
                            }
                        }
                    }
                } header: {
                    if let title = group.title { Text(verbatim: title) }
                }
            }
            if let footer = menu.footer {
                Divider()
                Button(footer.title, action: footer.run)
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if let icon = menu.icon { ChatSettingsIconView(icon: icon) }
                Text(verbatim: menu.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(menu.isEnabled ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Typography.disclosure)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.settingsControlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
                    .fill(hovered && menu.isEnabled ? Theme.Colors.controlHover : Theme.Colors.controlSurface))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!menu.isEnabled)
        .onHover { hovered = $0 }
        .help(menu.help ?? "")
        .accessibilityLabel(Text(verbatim: "\(menu.label): \(menu.title)"))
    }
}

/// This chat's MCP servers: all, some or none, as the composer's Tools menu chose them.
private struct ChatToolsSection: View {
    let tools: ChatToolsFacts

    var body: some View {
        Toggle(isOn: Binding(get: { tools.isEnabled }, set: { tools.setEnabled($0) })) {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("MCP Tools")
                    if !tools.takesTools {
                        Text("Not with this model")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    } else if tools.servers.isEmpty {
                        Text("No MCP servers are connected")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                ChatSettingsIconView(icon: .symbol("puzzlepiece.extension", .orange))
            }
        }
        .toggleStyle(ChatSwitchStyle())
        .disabled(!tools.takesTools || tools.servers.isEmpty)
        if tools.takesTools, tools.isEnabled {
            ForEach(tools.servers) { server in
                Toggle(isOn: Binding(get: { server.isOn }, set: { _ in tools.toggle(server.id) })) {
                    Text(verbatim: server.name)
                        .font(.callout)
                        .padding(.leading, Theme.Spacing.xxl + Theme.Spacing.xs)
                }
                .toggleStyle(.checkbox)
            }
        }
        Button("MCP Settings…", action: tools.showSettings)
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: Theme.Colors.accentInk))
            .font(.callout)
    }
}

/// Context and spend: the ring, what the last turn held, and what the chat has cost so far.
struct ChatUsageCard: View {
    let usage: ChatUsageFacts

    private var tint: Color {
        if usage.fill >= 1 { return Theme.Colors.destructive }
        return usage.fill >= 0.8 ? Theme.Colors.warning : RaycastHue.green.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    Circle().stroke(Theme.Colors.border, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: min(max(usage.fill, 0), 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Context")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(usage.fill.formatted(.percent.precision(.fractionLength(0))))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 0)
                if let cost = usage.chatCost {
                    VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                        Text("Chat cost")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text(cost.formatted(.currency(code: "USD").precision(.significantDigits(2))))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(RaycastHue.green.color)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.xs) {
                if let context = usage.contextTokens {
                    row("In context", tokens(context, of: usage.contextWindow))
                }
                if let input = usage.inputTokens {
                    let prompt = input + (usage.cachedTokens ?? 0)
                    row("Input", usage.cachedTokens.map {
                        String(localized: "\(prompt.formatted()) · \($0.formatted()) cached")
                    } ?? prompt.formatted())
                }
                if let output = usage.outputTokens {
                    row("Output", usage.reasoningTokens.map {
                        String(localized: "\(output.formatted()) · \($0.formatted()) thinking")
                    } ?? output.formatted())
                }
                if let total = usage.chatTokens {
                    row("Chat tokens", total.formatted())
                }
                if usage.contextTokens == nil, usage.inputTokens == nil {
                    row("Last reply", String(localized: "Not reported yet"))
                }
                row("Messages", String(localized: "\(usage.sentMessages) of \(usage.totalMessages)"))
                row("History", String(localized: "\(bytes(usage.historyBytes)) of \(bytes(usage.budget))"))
            }
            .font(.callout)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.chatSettingsCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke))
    }

    private func row(_ label: LocalizedStringResource, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.Colors.textSecondary)
            Text(verbatim: value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }

    private func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }

    private func tokens(_ count: Int, of window: Int?) -> String {
        guard let window else { return count.formatted() }
        return String(
            localized: "\(count.formatted()) of \(window.formatted(.number.notation(.compactName)))")
    }
}

/// A settings glyph: a symbol in its hue, a brand mark in its maker's, or a tile.
struct ChatSettingsIconView: View {
    let icon: ChatSettingsIcon
    var side: CGFloat = 16

    var body: some View {
        switch icon {
        case .symbol(let name, let hue):
            Image(systemName: name)
                .font(.system(size: side * 0.8, weight: .medium))
                .foregroundStyle(hue?.color ?? Theme.Colors.textSecondary)
                .frame(width: side, height: side)
        case .asset(let name, let hue):
            Image(nsImage: ChatSettingsIconImage.brand(name, side: side))
                .renderingMode(.template)
                .foregroundStyle(hue?.color ?? Theme.Colors.textPrimary)
                .frame(width: side, height: side)
        case .tile(let symbol, let hue):
            ChatFolderTile(symbol: symbol, hue: hue, size: side + 2)
        }
    }
}

/// Menus take images, not views, so each kind of glyph is drawn once at a menu's size.
enum ChatSettingsIconImage {
    static func make(_ icon: ChatSettingsIcon) -> NSImage {
        switch icon {
        case .symbol(let name, let hue):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
            guard let hue else { return image }
            let configuration = NSImage.SymbolConfiguration(paletteColors: [hue.tileNSColor])
            return image.withSymbolConfiguration(configuration) ?? image
        case .asset(let name, let hue):
            return brand(name, side: Theme.Size.menuBrandIcon, tint: hue)
        case .tile(let symbol, let hue):
            return ChatFolderTileImage.make(symbol: symbol, hue: hue)
        }
    }

    /// A tinted mark keeps its colour in a menu; an untinted one is a template, as the system's.
    static func brand(_ name: String, side: CGFloat, tint: RaycastHue? = nil) -> NSImage {
        guard let source = NSImage(named: name) else {
            return NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage()
        }
        let color = tint?.tileNSColor
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect)
            if let color {
                color.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}
