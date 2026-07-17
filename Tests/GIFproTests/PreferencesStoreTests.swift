import Foundation
import XCTest
@testable import GIFpro

final class PreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadReturnsDefaultsWhenNothingWasPersisted() {
        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.load(), .default)
    }

    func testSaveAndLoadRoundTripsAllRecordingSettings() {
        let store = PreferencesStore(defaults: defaults)
        let expected = RecordingSettings(
            scale: .two,
            fps: .fifteen,
            duration: .ninety,
            showsCursor: false
        )

        store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testInvalidScaleFallsBackWithoutChangingOtherFields() {
        let store = PreferencesStore(defaults: defaults)
        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set(999, forKey: "recording.scale")

        XCTAssertEqual(
            store.load(),
            .init(scale: .one, fps: .fifteen, duration: .ninety, showsCursor: false)
        )
    }

    func testInvalidFPSFallsBackWithoutChangingOtherFields() {
        let store = PreferencesStore(defaults: defaults)
        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set(999, forKey: "recording.fps")

        XCTAssertEqual(
            store.load(),
            .init(scale: .two, fps: .twelve, duration: .ninety, showsCursor: false)
        )
    }

    func testInvalidDurationFallsBackWithoutChangingOtherFields() {
        let store = PreferencesStore(defaults: defaults)
        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set(999, forKey: "recording.duration")

        XCTAssertEqual(
            store.load(),
            .init(scale: .two, fps: .fifteen, duration: .thirty, showsCursor: false)
        )
    }

    func testBooleanStoredForIntegerFieldFallsBackWithoutChangingOtherFields() {
        let store = PreferencesStore(defaults: defaults)
        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set(true, forKey: "recording.scale")

        XCTAssertEqual(
            store.load(),
            .init(scale: .one, fps: .fifteen, duration: .ninety, showsCursor: false)
        )
    }

    func testIntegerStoredForBooleanFieldFallsBackWithoutChangingOtherFields() {
        let store = PreferencesStore(defaults: defaults)
        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set(1, forKey: "recording.showsCursor")

        XCTAssertEqual(
            store.load(),
            .init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: true)
        )
    }

    func testStringsStoredForPersistedFieldsFallBackIndependently() {
        let store = PreferencesStore(defaults: defaults)
        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))

        defaults.set("2", forKey: "recording.scale")
        XCTAssertEqual(store.load(), .init(scale: .one, fps: .fifteen, duration: .ninety, showsCursor: false))

        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set("15", forKey: "recording.fps")
        XCTAssertEqual(store.load(), .init(scale: .two, fps: .twelve, duration: .ninety, showsCursor: false))

        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set("90", forKey: "recording.duration")
        XCTAssertEqual(store.load(), .init(scale: .two, fps: .fifteen, duration: .thirty, showsCursor: false))

        store.save(.init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: false))
        defaults.set("false", forKey: "recording.showsCursor")
        XCTAssertEqual(store.load(), .init(scale: .two, fps: .fifteen, duration: .ninety, showsCursor: true))
    }
}
