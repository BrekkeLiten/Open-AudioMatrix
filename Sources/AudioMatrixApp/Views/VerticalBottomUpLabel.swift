import SwiftUI

/// Vertical label reading bottom → top (Dante-style), centered in `containerWidth`.
struct VerticalBottomUpLabel: View {
    let text: String
    let railHeight: CGFloat
    var containerWidth: CGFloat?
    var foregroundStyle: Color = .primary

    @State private var textWidth: CGFloat = 0

    private var outerWidth: CGFloat {
        max(containerWidth ?? MatrixTheme.sourceLabelRailWidth, MatrixTheme.sourceLabelRailWidth)
    }

    private var fitScale: CGFloat {
        guard textWidth > 0 else { return 1 }
        return min(1, railHeight / textWidth)
    }

    var body: some View {
        Text(text)
            .font(.system(size: MatrixTheme.sourceLabelFontSize, weight: .semibold))
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(fitScale, anchor: .center)
            .rotationEffect(.degrees(-90), anchor: .center)
            .frame(width: outerWidth, height: railHeight, alignment: .center)
            .background {
                if textWidth == 0 {
                    Text(text)
                        .font(.system(size: MatrixTheme.sourceLabelFontSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        textWidth = proxy.size.width
                                    }
                            }
                        }
                        .hidden()
                }
            }
            .onChange(of: text) { _, _ in
                textWidth = 0
            }
    }
}
