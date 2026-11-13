import SwiftUI

struct SymbolPicker: View {
    @Binding var selection: String?
    /// Drawn on the Automatic row, and what the row falls back to when nothing is picked.
    let fallback: String
    let symbols: [String]
    let onPick: () -> Void

    private static let cell: CGFloat = 30
    private static let cellHeight: CGFloat = 26
    private static let columnCount = 6

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.cell), spacing: Theme.Spacing.sm), count: Self.columnCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button {
                selection = nil
                onPick()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    SymbolImage(name: fallback, size: 14)
                    Text("Automatic")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: Theme.Size.settingsControlHeight)
            }
            .settingsControl(.pickerRow(isSelected: selection == nil))
            Divider()
            LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        selection = symbol
                        onPick()
                    } label: {
                        SymbolImage(name: symbol, size: 15)
                            .frame(width: Self.cell, height: Self.cellHeight)
                    }
                    .settingsControl(.pickerRow(isSelected: selection == symbol, isCell: true))
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: Self.width)
        .settingsEditorPanelSurface()
    }

    private static let width: CGFloat = 252
}
