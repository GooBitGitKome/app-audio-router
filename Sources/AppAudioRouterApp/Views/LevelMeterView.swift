import SwiftUI

/// Compact visual level meter showing real-time audio amplitude.
public struct LevelMeterView: View {
    public let level: Float

    public init(level: Float) {
        self.level = min(max(level, 0.0), 1.0)
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))

                // Active level bar
                RoundedRectangle(cornerRadius: 3)
                    .fill(meterGradient)
                    .frame(width: max(0, geometry.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [.green, .yellow, .red]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
