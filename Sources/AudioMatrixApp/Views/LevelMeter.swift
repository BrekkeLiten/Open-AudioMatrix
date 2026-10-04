import SwiftUI

struct LevelMeter: View {
    let level: Float

    @State private var displayedLevel: Float = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(displayedLevel > 0.8 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(displayedLevel, 1.0)))
            }
        }
        .frame(height: 8)
        .onAppear { displayedLevel = level }
        .onChange(of: level) { _, newValue in
            animateLevel(to: newValue)
        }
    }

    private func animateLevel(to newValue: Float) {
        let duration = newValue > displayedLevel ? 0.025 : 0.07
        withAnimation(.linear(duration: duration)) {
            displayedLevel = newValue
        }
    }
}

/// Vertical level bar for transmitter column headers (fills bottom → top).
struct VerticalLevelMeter: View {
    let level: Float

    @State private var displayedLevel: Float = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.25))
                RoundedRectangle(cornerRadius: 1)
                    .fill(displayedLevel > 0.8 ? Color.red : Color.green)
                    .frame(height: geo.size.height * CGFloat(min(displayedLevel, 1.0)))
            }
        }
        .onAppear { displayedLevel = level }
        .onChange(of: level) { _, newValue in
            animateLevel(to: newValue)
        }
    }

    private func animateLevel(to newValue: Float) {
        let duration = newValue > displayedLevel ? 0.025 : 0.07
        withAnimation(.linear(duration: duration)) {
            displayedLevel = newValue
        }
    }
}
