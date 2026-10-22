import SwiftUI

/// A custom action's `{argument}` fields in root search, keyed by the names its prompt declares.
@MainActor
enum QuickActionArgumentsAccessory {
    static func make(
        action: CustomQuickAction?,
        vm: PaletteState,
        metrics: InterfaceMetrics,
        focus: FocusState<String?>.Binding,
        onOpenOptions: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) -> PaletteHeaderAccessory? {
        guard let action else { return nil }
        let arguments = QuickActionTemplate.arguments(in: action).map {
            InlineArgument(
                id: $0.name, title: $0.name, options: $0.options, isOptional: $0.isOptional)
        }
        guard !arguments.isEmpty else { return nil }
        let value = { (name: String) in binding(action: action, name: name, vm: vm) }
        let firstOwed = {
            arguments.first { !$0.isOptional && value($0.id).wrappedValue.isEmpty }?.id
        }
        return PaletteHeaderAccessory(
            width: InlineArgumentFields.totalWidth(for: arguments, hasIcon: true, metrics: metrics),
            fieldNames: arguments.map(\.id),
            firstIncompleteField: firstOwed(),
            optionsMenu: { id in
                guard let argument = arguments.first(where: { $0.id == id }),
                    !argument.options.isEmpty
                else { return nil }
                return menu(for: argument, value: value(id))
            },
            // Identity per row, so which fields were left unanswered resets on the next one.
            view: AnyView(
                InlineArgumentFields(
                    arguments: arguments, symbol: action.symbol, value: value, focused: focus,
                    openOptions: onOpenOptions,
                    // A run that starts short would only reopen these same fields.
                    onSubmit: {
                        guard let owed = firstOwed() else { return onSubmit() }
                        focus.wrappedValue = owed
                    }
                )
                .id(action.entryID))
        )
    }

    static func values(for action: CustomQuickAction, vm: PaletteState) -> [String: String] {
        var values: [String: String] = [:]
        for argument in QuickActionTemplate.arguments(in: action) {
            let typed =
                vm.commandArguments[PaletteState.argumentKey(action.entryID, argument.name)] ?? ""
            if !typed.isEmpty { values[argument.name] = typed }
        }
        return values
    }

    private static func binding(
        action: CustomQuickAction, name: String, vm: PaletteState
    ) -> Binding<String> {
        let key = PaletteState.argumentKey(action.entryID, name)
        return Binding(get: { vm.commandArguments[key] ?? "" }, set: { vm.commandArguments[key] = $0 })
    }

    private static func menu(
        for argument: InlineArgument, value: Binding<String>
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            header: argument.title,
            items: argument.options.map { option in
                PopoverMenuItem(
                    title: option,
                    icon: value.wrappedValue == option ? .symbol("checkmark") : .blank
                ) {
                    value.wrappedValue = option
                }
            })
    }
}
