import Foundation
import XCTest
@testable import BillLensShared

final class SubscriptionNotificationContractsTests: XCTestCase {
    func testReminderUsesDeviceTimeZoneAtNineAM() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let first = try SubscriptionNotificationService.reminderComponents(dueDate: "2026-10-22", timeZone: losAngeles)
        let second = try SubscriptionNotificationService.reminderComponents(dueDate: "2026-10-22", timeZone: shanghai)
        XCTAssertEqual(first.hour, 9)
        XCTAssertEqual(first.timeZone, losAngeles)
        XCTAssertEqual(second.hour, 9)
        XCTAssertEqual(second.timeZone, shanghai)
        XCTAssertNotEqual(first.date, second.date)
    }

    func testInvalidDatesAreRejectedInsteadOfRollingIntoAnotherMonth() {
        for value in ["2026-02-30", "2026-13-01", "2026-00-01", "2026-1-01", "2026-10-22-extra"] {
            XCTAssertThrowsError(try SubscriptionNotificationService.reminderComponents(dueDate: value, timeZone: .gmt))
        }
    }
}
