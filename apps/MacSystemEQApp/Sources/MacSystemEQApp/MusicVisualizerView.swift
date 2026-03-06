import SwiftUI

struct MusicVisualizerView: View {
    let samples: [Float]
    let isEnabled: Bool

    var body: some View {
        GeometryReader { geometry in
            let bars = max(samples.count, 1)
            let spacing: CGFloat = 3
            let totalSpacing = spacing * CGFloat(max(bars - 1, 0))
            let barWidth = max(2, (geometry.size.width - totalSpacing) / CGFloat(bars))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(gradient(for: sample))
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(max(0, min(1, sample))) * geometry.size.height)
                        )
                        .opacity(isEnabled ? 1 : 0.35)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func gradient(for sample: Float) -> LinearGradient {
        let clamped = max(0, min(1, sample))
        let top = Color(
            red: Double(0.2 + 0.7 * clamped),
            green: Double(0.9 - 0.5 * clamped),
            blue: Double(0.35)
        )
        let bottom = Color(
            red: Double(0.1),
            green: Double(0.45),
            blue: Double(0.25 + 0.35 * clamped)
        )
        return LinearGradient(colors: [bottom, top], startPoint: .bottom, endPoint: .top)
    }
}
