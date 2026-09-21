import XCTest
@testable import Squidd

final class SquiddTests: XCTestCase {
    func test_minimumSize_isExpected() {
        XCTAssertEqual(WidgetGeometry.minimum, CGSize(width: 282, height: 170))
    }
}
