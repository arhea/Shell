import SwiftUI

/// Claude's spark mark: tapered rays of uneven length around a center.
struct ClaudeLogoShape: Shape {
    private static let rays: [CGFloat] = [1.0, 0.82, 0.95, 0.78, 1.0, 0.86, 0.93, 0.8, 0.98, 0.84, 0.9, 0.79]

    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = size / 2
        let width = size * 0.13
        var path = Path()
        for (i, length) in Self.rays.enumerated() {
            let angle = CGFloat(i) / CGFloat(Self.rays.count) * 2 * .pi - .pi / 2
            let ray = Path(roundedRect: CGRect(x: radius * 0.12, y: -width / 2, width: radius * length * 0.88, height: width),
                           cornerRadius: width / 2)
            path.addPath(ray, transform: CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        }
        return path
    }
}
