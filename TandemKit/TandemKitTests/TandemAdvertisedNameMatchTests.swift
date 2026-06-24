import XCTest
import Foundation
import CoreBluetooth
@testable import TandemKit

// TandemAdvertisedNameMatchTests
// ------------------------------
// Guards the BLE discovery name filter (isTandemMobi). A real Tandem Mobi
// advertises its model name with a unit-specific suffix, e.g. "Tandem Mobi 883".
// The original filter used exact equality against "Tandem Mobi", which never
// matched a real unit, so centralManager(_:didDiscover:) silently dropped every
// pump and discovery never progressed. The filter now matches by prefix.
//
// These tests exercise isTandemMobi directly. It is a pure function of the
// advertised name (the advertisementData argument is reserved for future use),
// so no live CoreBluetooth manager is needed. Construction still uses the proven
// offline seam — a nil-returning central factory — so no CBCentralManager is
// built and the eager state-restoration authorization probe never runs. The
// pump manager is held for the test's duration because TandemBLEManager holds
// it weakly.
final class TandemAdvertisedNameMatchTests: XCTestCase {

    private var pumpManager: TandemPumpManager!
    private var bleManager: TandemBLEManager!

    override func setUp() {
        super.setUp()
        let state = TandemPumpState(basalRateSchedule: nil)
        pumpManager = TandemPumpManager(state: state, centralFactory: { _, _ in nil })
        bleManager = TandemBLEManager(pumpManager: pumpManager, centralFactory: { _, _ in nil })
    }

    override func tearDown() {
        bleManager = nil
        pumpManager = nil
        super.tearDown()
    }

    // A Mobi advertising with a serial suffix must match. This is the exact name
    // the live pump put on the air ("Tandem Mobi 883") and the case the old
    // exact-equality filter failed to match.
    func testMobiWithSerialSuffixMatches() {
        XCTAssertTrue(bleManager.isTandemMobi(name: "Tandem Mobi 883", advertisementData: [:]))
    }

    // The bare model name must still match (defensive: some firmware may omit the
    // suffix).
    func testBareMobiNameMatches() {
        XCTAssertTrue(bleManager.isTandemMobi(name: "Tandem Mobi", advertisementData: [:]))
    }

    // A t:slim X2 with a trailing identifier must match by prefix.
    func testTslimX2WithSuffixMatches() {
        XCTAssertTrue(bleManager.isTandemMobi(name: "tslim X2 1234", advertisementData: [:]))
    }

    func testBareTslimX2NameMatches() {
        XCTAssertTrue(bleManager.isTandemMobi(name: "tslim X2", advertisementData: [:]))
    }

    // Unrelated devices must never match. The FDFB service scan filter already
    // gates discovery, but the name filter must not admit foreign peripherals.
    func testUnrelatedDeviceDoesNotMatch() {
        XCTAssertFalse(bleManager.isTandemMobi(name: "Dexcom G7", advertisementData: [:]))
        XCTAssertFalse(bleManager.isTandemMobi(name: "Omnipod", advertisementData: [:]))
        XCTAssertFalse(bleManager.isTandemMobi(name: "", advertisementData: [:]))
    }

    // A name that merely contains, but does not start with, the model string must
    // not match — prefix semantics, not substring.
    func testNonPrefixContainingNameDoesNotMatch() {
        XCTAssertFalse(bleManager.isTandemMobi(name: "My Tandem Mobi", advertisementData: [:]))
    }
}
