import SwiftUI

struct CustomCommandPreview: View {
    @Environment(\.metrics) private var metrics
    @Environment(HotKeyManager.self) private var hotKeys
    let command: CustomCommand?

    private func information(for command: CustomCommand) -> [PreviewInfoRow] {
        var rows = [
            PreviewInfoRow(
                String(localized: "Run In"), command.workingDirectory ?? String(localized: "Home folder")),
            PreviewInfoRow(
                String(localized: "Output"),
                command.showsOutput ? String(localized: "Show output") : String(localized: "Silent"))
        ]
        if !command.arguments.isEmpty {
            let arguments = command.arguments.enumerated().map { index, argument in
                let name = "\(CustomCommandArgument.fieldID(at: index)) · \(argument.name)"
                return argument.isOptional ? String(localized: "\(name) (optional)") : name
            }
            rows.append(
                PreviewInfoRow(String(localized: "Arguments"), arguments.joined(separator: ", ")))
        }
        if command.requiresConfirmation {
            rows.append(
                PreviewInfoRow(String(localized: "Confirmation"), String(localized: "Required before running")))
        }
        if let keycaps = hotKeys.binding(for: .customCommand(id: command.id))?.keycaps {
            rows.append(PreviewInfoRow(String(localized: "Shortcut"), keycaps: keycaps))
        }
        return rows
    }

    var body: some View {
        if let command {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(command.command)
                        .font(metrics.typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(metrics.spacing.lg)
                }
                .id(command.id)
                .previewStage(filled: true)
                .padding(.top, metrics.spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                PreviewInfoSection(rows: information(for: command))
                    .padding(.vertical, metrics.spacing.md)
            }
            .padding(.horizontal, metrics.spacing.xl)
        } else {
            Color.clear
        }
    }
}
