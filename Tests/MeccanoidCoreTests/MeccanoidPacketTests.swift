import Foundation
import XCTest
@testable import MeccanoidCore

final class MeccanoidPacketTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testHandshakeAndReadRequestsMatchWireFixtures() {
        XCTAssertEqual(MeccanoidPacket.pin(), data("1a 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 1c"))
        XCTAssertEqual(MeccanoidPacket.status(), data("01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01"))
        XCTAssertEqual(MeccanoidPacket.readPose(), data("09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 09"))
    }

    func testStopPacketsAreDistinctAndHaveExactPayloads() throws {
        let zero = data("0d 02 02 00 00 ff ff 00 00 00 00 00 00 00 00 00 00 00 02 0f")
        XCTAssertEqual(MeccanoidPacket.zeroWheels(), zero)
        XCTAssertEqual(try MeccanoidPacket.wheels(left: 0, right: 0), zero)
        XCTAssertEqual(MeccanoidPacket.stopPreset(), data("19 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 21"))
    }

    func testEyeChannelPackingMatchesWireFixtures() throws {
        XCTAssertEqual(try MeccanoidPacket.eyes(red: 7, green: 0, blue: 0),
                       data("11 00 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 18"))
        XCTAssertEqual(try MeccanoidPacket.eyes(red: 5, green: 6, blue: 7),
                       data("11 00 00 35 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4d"))
        XCTAssertNoThrow(try MeccanoidPacket.eyes(red: 0, green: 0, blue: 0))
        XCTAssertNoThrow(try MeccanoidPacket.eyes(red: 7, green: 7, blue: 7))
    }

    func testEachEyeChannelRejectsOutOfRangeIncludingIntegerExtremes() {
        for invalid in [-1, 8, Int.min, Int.max] {
            XCTAssertThrowsError(try MeccanoidPacket.eyes(red: invalid, green: 0, blue: 0))
            XCTAssertThrowsError(try MeccanoidPacket.eyes(red: 0, green: invalid, blue: 0))
            XCTAssertThrowsError(try MeccanoidPacket.eyes(red: 0, green: 0, blue: invalid))
        }
    }

    func testWheelDirectionsAndChecksumCarryMatchFixture() throws {
        XCTAssertEqual(try MeccanoidPacket.wheels(left: -40, right: 60),
                       data("0d 02 01 28 3c ff ff 00 00 00 00 00 00 00 00 00 00 00 02 72"))
        let bounded = try MeccanoidPacket.wheels(left: 100, right: -100)
        XCTAssertEqual(Array(bounded.prefix(7)), [0x0d, 1, 2, 100, 100, 255, 255])
        XCTAssertNotNil(MeccanoidPacket.decode(bounded))
    }

    func testWheelBoundIsRawPWMAndRejectsBothSidesBeforeAbsConversion() {
        for invalid in [-101, 101, -255, 255, Int.min, Int.max] {
            XCTAssertThrowsError(try MeccanoidPacket.wheels(left: invalid, right: 0))
            XCTAssertThrowsError(try MeccanoidPacket.wheels(left: 0, right: invalid))
        }
    }

    func testServoModesFillSixteenSlotsAndLeaveLastPayloadByteZero() throws {
        XCTAssertEqual(try MeccanoidPacket.servoMode(2),
                       data("0b 02 02 02 02 02 02 02 02 02 02 02 02 02 02 02 02 00 00 2b"))
        XCTAssertEqual(try MeccanoidPacket.servoMode(4),
                       data("0b 04 04 04 04 04 04 04 04 04 04 04 04 04 04 04 04 00 00 4b"))
        for invalid in [Int.min, -1, 0, 1, 3, 5, 255, Int.max] {
            XCTAssertThrowsError(try MeccanoidPacket.servoMode(invalid)) { error in
                XCTAssertEqual(error as? MeccanoidPacketError, .unsupportedServoMode(invalid))
            }
        }
    }

    func testPoseIncludesEverySlotAndNineTrailingOnes() throws {
        XCTAssertEqual(try MeccanoidPacket.pose([24, 232, 128, 129, 130, 131, 132, 133]),
                       data("08 18 e8 80 81 82 83 84 85 01 01 01 01 01 01 01 01 01 04 20"))
        // This is a raw codec; calibrated limits are enforced by its caller.
        XCTAssertEqual(try MeccanoidPacket.pose(Array(repeating: 255, count: 8)),
                       data("08 ff ff ff ff ff ff ff ff 01 01 01 01 01 01 01 01 01 08 09"))
        for count in [0, 1, 7, 9, 16] {
            XCTAssertThrowsError(try MeccanoidPacket.pose(Array(repeating: 128, count: count))) { error in
                XCTAssertEqual(error as? MeccanoidPacketError, .invalidPoseCount(count))
            }
        }
    }

    func testCapturedPinReplyIsAcceptedAndOriginalRejectionPrefixIsRejected() {
        // Captured battery-powered G15KS reply documented by Robot club.
        let accepted = data("1a 01 00 01 00 ff ff ff ff ff ff ff ff ff ff ff ff ff 0d 0f")
        XCTAssertEqual(MeccanoidPacket.decode(accepted), .pin(accepted: true))
        let rejected = data("1a 00 01 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 1a")
        XCTAssertEqual(MeccanoidPacket.decode(rejected), .pin(accepted: false))
    }

    func testCapturedStatusPreservesCodesWithoutInventingPhysicalUnits() {
        let raw = data("01 04 00 01 0a 07 00 00 00 00 07 72 04 00 14 00 00 00 00 a8")
        XCTAssertEqual(MeccanoidPacket.decode(raw), .status(RobotStatus(
            buttons: RobotButtons(blue: false, red: false, green: false, yellow: false),
            chestLEDs: 0, motorCurrentCode: 7, servoCurrentCode: 114,
            batteryCode: 4, limCount: 0, presetCount: 20, errorCode: 0, raw: Array(raw)
        )))
    }

    func testStatusOffsetsAndButtonBitsAreNotShifted() {
        let raw = data("01 11 12 13 14 15 16 17 0d 19 1a 1b 1c 1d 1e 1f 20 21 01 9f")
        XCTAssertEqual(MeccanoidPacket.decode(raw), .status(RobotStatus(
            buttons: RobotButtons(blue: true, red: false, green: true, yellow: true),
            chestLEDs: 0x19, motorCurrentCode: 0x1a, servoCurrentCode: 0x1b,
            batteryCode: 0x1c, limCount: 0x1d, presetCount: 0x1e, errorCode: 0x20, raw: Array(raw)
        )))
        XCTAssertEqual(RobotButtons(bitfield: 0xf2), RobotButtons(blue: false, red: true, green: false, yellow: false))
    }

    func testPoseReplyExtractsOnlyEightPositions() {
        let raw = data("09 01 02 03 04 05 06 07 08 00 00 00 00 00 00 00 00 00 00 2d")
        XCTAssertEqual(MeccanoidPacket.decode(raw), .pose([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testUnknownCommandRetainsAllPayloadBytesWithoutChecksum() {
        let raw = data("7e 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 01 17")
        XCTAssertEqual(MeccanoidPacket.decode(raw), .other(command: 0x7e, payload: Array(1...17)))
    }

    func testRejectsEverySingleByteMutationIncludingEitherChecksumByte() {
        let fixture = data("1a 01 00 01 00 ff ff ff ff ff ff ff ff ff ff ff ff ff 0d 0f")
        for index in 0..<20 {
            var corrupted = fixture
            corrupted[index] ^= 1
            XCTAssertNil(MeccanoidPacket.decode(corrupted), "Mutation at byte \(index)")
        }
    }

    func testRejectsTruncatedOversizedAndConcatenatedFrames() {
        let fixture = MeccanoidPacket.pin()
        for size in 0..<20 {
            XCTAssertNil(MeccanoidPacket.decode(fixture.prefix(size)))
        }
        XCTAssertNil(MeccanoidPacket.decode(fixture + Data([0])))
        XCTAssertNil(MeccanoidPacket.decode(fixture + fixture))
    }

    func testDataSliceWithNonzeroIndexDoesNotTrapOrMisdecode() {
        let prefixed = Data([255]) + data("1a 01 00 01 00 ff ff ff ff ff ff ff ff ff ff ff ff ff 0d 0f")
        let slice = prefixed.dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        XCTAssertEqual(MeccanoidPacket.decode(slice), .pin(accepted: true))
    }
}
