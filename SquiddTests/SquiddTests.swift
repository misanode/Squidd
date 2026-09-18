//
//  SquiddTests.swift
//  SquiddTests
//
//  Created by Misael Taperia on 9/18/26.
//

import XCTest
@testable import Squidd

final class SquiddTests: XCTestCase {
    func test_minimumSize_isExpected() {
        XCTAssertEqual(WidgetGeometry.minimum, CGSize(width: 282, height: 170))
    }
}
