import XCTest
@testable import Kontrol

final class ProjectSmokeTests: XCTestCase {
    func testAppTargetLoads() {
        XCTAssertEqual(KontrolApp.bootstrapTitle, "Kontrol")
    }
}
