import SwiftUI

/// Expand control shown in place of crosspoints when a source or destination group is collapsed.
struct MatrixExpandCell: View {
    let onExpand: () -> Void
    var slotWidth: CGFloat = MatrixTheme.cellColumnWidth
    var slotHeight: CGFloat = MatrixTheme.rowHeight

    var body: some View {
        Button(action: onExpand) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(MatrixTheme.disconnectedFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(MatrixTheme.disconnectedBorder, lineWidth: 0.5)
                    }
                    .frame(width: MatrixTheme.cellSize, height: MatrixTheme.cellSize)

                MatrixExpandToggleLabel(isExpanded: false)
            }
            .frame(width: slotWidth, height: slotHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
