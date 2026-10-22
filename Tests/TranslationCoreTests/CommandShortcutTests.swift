import XCTest
import CoreGraphics
import Carbon
@testable import TranslationCore

final class CommandShortcutTests: XCTestCase {
    func testCopyAndPasteReleaseCommandAfterShortcut() throws {
        for key in [kVK_ANSI_C, kVK_ANSI_V] {
            let events = try CommandShortcut.events(key: CGKeyCode(key))
            XCTAssertEqual(events.count, 4)
            // macOS 把独立修饰键事件表示为 flagsChanged。
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                [Int64(kVK_Command), Int64(key), Int64(key), Int64(kVK_Command)])
            XCTAssertTrue(events.prefix(3).allSatisfy { $0.flags == .maskCommand })
            XCTAssertTrue(try XCTUnwrap(events.last).flags.isEmpty)
            XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == CommandShortcut.eventMarker })
            XCTAssertFalse(events.contains { $0.getIntegerValueField(.keyboardEventKeycode) == kVK_Return })
        }
    }
}
