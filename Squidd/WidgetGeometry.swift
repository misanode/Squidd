import Foundation
import CoreGraphics

enum WidgetGeometry {
    static let minimum = CGSize(width: 282, height: 170)
    static let launcherAllowance: CGFloat = 72

    static func fit(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(minimum.width, frame.width), screen.width)
        let height = min(max(minimum.height, frame.height), max(1, screen.height - launcherAllowance))
        return CGRect(x: max(screen.minX, min(frame.minX, screen.maxX - width)),
                      y: max(screen.minY, min(frame.minY, screen.maxY - height - launcherAllowance)),
                      width: width, height: height)
    }

    static func launcher(for card: CGRect) -> CGRect {
        CGRect(x: card.midX - 84.5, y: card.maxY - 8, width: 169, height: 80)
    }
}
