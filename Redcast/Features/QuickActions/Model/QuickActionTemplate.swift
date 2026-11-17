import Foundation

/// A custom action's instructions take the snippet placeholders, resolved once as a run starts.
enum QuickActionTemplate {
    enum Resolution: Equatable, Sendable {
        case ready(CustomQuickAction)
        case needsArguments
    }

    /// The selection travels as the user message, so inside the instructions it only names it.
    static let selectionReference = "the text below"

    static func arguments(in action: CustomQuickAction) -> [SnippetTemplateEngine.DeclaredArgument] {
        SnippetTemplateEngine.declaredArguments(in: action.instructions)
    }

    static func resolve(
        _ action: CustomQuickAction, context: SnippetTemplateEngine.ExpansionContext,
        values: [String: String]
    ) -> Resolution {
        var context = context
        context.selection = selectionReference
        let expansion = SnippetTemplateEngine.expand(
            text: action.instructions, context: context, userArguments: values)
        guard expansion.missingArguments.isEmpty else { return .needsArguments }
        var resolved = action
        resolved.instructions = expansion.text
        return .ready(resolved)
    }
}
