import SwiftUI

/// Shared +/− glyph for expand controls.
struct MatrixExpandToggleLabel: View {
    let isExpanded: Bool

    var body: some View {
        Text(isExpanded ? "−" : "+")
            .font(.system(size: MatrixTheme.expandToggleFontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(
                width: MatrixTheme.expandToggleSize,
                height: MatrixTheme.expandToggleSize
            )
    }
}

/// Uniform +/− expand control used in source band headers and receiver sidebar blocks.
struct MatrixExpandToggleButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MatrixExpandToggleLabel(isExpanded: isExpanded)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: MatrixTheme.expandToggleSize,
            height: MatrixTheme.expandToggleSize
        )
        .contentShape(Rectangle())
    }
}
