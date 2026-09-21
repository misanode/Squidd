import Foundation
import CoreGraphics

@main
enum GeometryChecks {
    static func main() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1000)
        let original = CGRect(x: -1200, y: 400, width: 316, height: 192)
        let launcher = WidgetGeometry.launcher(for: original)
        assert(launcher.midX == original.midX)
        assert(launcher.minY + 14 - original.maxY == 6)
        for screen in [screen, CGRect(x: 0, y: -900, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 200, height: 200)] {
            let fitted = WidgetGeometry.fit(CGRect(x: 99999, y: -99999, width: 9000, height: 9000), in: screen)
            assert(screen.contains(fitted))
            assert(fitted.maxY + WidgetGeometry.launcherAllowance <= screen.maxY)
            assert(WidgetGeometry.fit(fitted, in: screen) == fitted)
        }
        print("Geometry checks passed: negative screen coordinates, small displays, launcher spacing, and idempotent clamping.")
    }
}
