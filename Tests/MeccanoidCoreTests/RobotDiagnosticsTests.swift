import Foundation
import XCTest
@testable import MeccanoidCore

final class RobotDiagnosticsTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // Read-only replies from a four-servo assembly. No device identifiers or
    // anatomical assumptions are needed to reproduce the inventory mismatch.
    private var firstBankReply: Data {
        data("02 01 01 00 00 02 00 00 00 01 00 00 00 01 00 00 00 00 00 08")
    }
    private var secondBankReply: Data {
        data("03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03")
    }
    private var mappingReply: Data {
        data("20 22 21 20 00 01 02 10 11 ff ff ff ff ff ff ff ff 00 08 9f")
    }
    private var modesReply: Data {
        data("0a 00 00 04 04 04 00 00 00 00 00 00 00 00 00 00 00 00 00 16")
    }

    private func capturedDiagnostics() throws -> RobotDiagnostics {
        guard case .modules(let bank1, let first)? = MeccanoidPacket.decode(firstBankReply),
              case .modules(let bank2, let second)? = MeccanoidPacket.decode(secondBankReply),
              case .servoMapping(let mapping)? = MeccanoidPacket.decode(mappingReply),
              case .servoModes(let modes)? = MeccanoidPacket.decode(modesReply) else {
            XCTFail("Captured diagnostic replies did not decode")
            throw NSError(domain: "TestFixture", code: 1)
        }
        XCTAssertEqual(bank1, .channels1to4)
        XCTAssertEqual(bank2, .channels5to8)
        return try XCTUnwrap(RobotDiagnostics(firstBank: first, secondBank: second, mapping: mapping, modes: modes))
    }

    func testDiagnosticRequestsHaveOnlyGetterCommandAndChecksum() {
        XCTAssertEqual(MeccanoidPacket.readModules(.channels1to4),
                       data("02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 02"))
        XCTAssertEqual(MeccanoidPacket.readModules(.channels5to8),
                       data("03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03"))
        XCTAssertEqual(MeccanoidPacket.readServoMapping(),
                       data("20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 20"))
        XCTAssertEqual(MeccanoidPacket.readServoModes(),
                       data("0a 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0a"))
    }

    func testCapturedInventoryHasFourServosButOnlyThreeInFirstEightMappedSlots() throws {
        let diagnostics = try capturedDiagnostics()
        XCTAssertEqual(diagnostics.modules.count, 32)
        XCTAssertEqual(diagnostics.servoCount, 4)
        XCTAssertEqual(diagnostics.modules.filter(\.isServo).map(\.address.rawValue), [0x00, 0x01, 0x20, 0x30])
        XCTAssertEqual(diagnostics.firstEightMappedServoSlots.map(\.slotIndex), [2, 3, 4])
        XCTAssertEqual(diagnostics.firstEightMappedServoSlots.map(\.rawAddress), [0x20, 0x00, 0x01])
        XCTAssertEqual(diagnostics.unmappedServoAddresses.map(\.rawValue), [0x30])
        XCTAssertEqual(diagnostics.unmappedServoAddresses.first?.displayName, "Channel 4, position 1")
        // UI Joint 3 is slot index 2, and is a configured servo despite other
        // mapping gaps. Do not claim the gaps explain that joint's nonmovement.
        XCTAssertTrue(diagnostics.mappedSlots[2].isConfiguredServo)
        XCTAssertEqual(diagnostics.mappedSlots[2].address?.channelIndex, 2)
        XCTAssertEqual(diagnostics.mappedSlots[2].address?.positionIndex, 0)
    }

    func testMappingKeepsLEDAndEmptyPositionsDistinctFromUnassigned() throws {
        let slots = try capturedDiagnostics().mappedSlots
        XCTAssertEqual(slots.count, 16)
        XCTAssertEqual(slots[6].moduleTypeCode, 2)
        XCTAssertFalse(slots[6].isConfiguredServo)
        XCTAssertEqual(slots[6].summary, "Channel 2, position 1: LED")
        XCTAssertEqual(slots[0].moduleTypeCode, 0)
        XCTAssertEqual(slots[0].summary, "Channel 3, position 3: No module reported")
        XCTAssertNil(slots[8].moduleTypeCode)
        XCTAssertNil(slots[8].address)
        XCTAssertEqual(slots[8].rawAddress, 0xFF)
        XCTAssertEqual(slots[8].summary, "Unassigned (0xFF)")
    }

    func testSeventeenthPayloadByteIsNotAnExtraMappingOrMode() throws {
        let diagnostics = try capturedDiagnostics()
        XCTAssertEqual(diagnostics.mapping, [0x22, 0x21, 0x20, 0, 1, 2, 0x10, 0x11] + Array(repeating: 0xFF, count: 8))
        XCTAssertEqual(diagnostics.modes, [0, 0, 4, 4, 4] + Array(repeating: 0, count: 11))
        XCTAssertEqual(diagnostics.mappedSlots[2].modeCode, 4)
        var changedUnusedByte = mappingReply
        changedUnusedByte[17] = 0x7F
        changedUnusedByte[18] = 0x09
        changedUnusedByte[19] = 0x1E
        XCTAssertEqual(MeccanoidPacket.decode(changedUnusedByte), .servoMapping(diagnostics.mapping))
    }

    func testUnknownTypesModesAndInvalidAddressesArePreserved() throws {
        var first = Array(repeating: UInt8(0), count: 16)
        var second = first
        first[0] = 0xA5
        first[1] = 3
        second[15] = 1 // Last possible address: channel 8, position 4.
        var mapping = Array(repeating: UInt8(0xFF), count: 16)
        mapping.replaceSubrange(0..<5, with: [0x00, 0x80, 0x04, 0x73, 0x01])
        let modes = Array(repeating: UInt8(0xE7), count: 16)
        let diagnostics = try XCTUnwrap(RobotDiagnostics(firstBank: first, secondBank: second, mapping: mapping, modes: modes))
        XCTAssertEqual(diagnostics.firstBank, first)
        XCTAssertEqual(diagnostics.mapping, mapping)
        XCTAssertEqual(diagnostics.modes, modes)
        XCTAssertEqual(diagnostics.modules[0].typeDescription, "Unknown type (0xA5)")
        XCTAssertEqual(diagnostics.mappedSlots[0].moduleTypeCode, 0xA5)
        XCTAssertEqual(diagnostics.mappedSlots[0].modeCode, 0xE7)
        XCTAssertNil(diagnostics.mappedSlots[1].address)
        XCTAssertNil(diagnostics.mappedSlots[2].address)
        XCTAssertEqual(diagnostics.mappedSlots[1].summary, "Unknown address (0x80)")
        XCTAssertEqual(diagnostics.mappedSlots[2].rawAddress, 0x04)
        XCTAssertEqual(diagnostics.mappedSlots[3].address?.displayName, "Channel 8, position 4")
        XCTAssertEqual(diagnostics.mappedSlots[4].moduleTypeCode, 3)
        XCTAssertEqual(diagnostics.modules[1].typeDescription, "Roller")
        XCTAssertEqual(diagnostics.firstEightMappedServoSlots.map(\.slotIndex), [3])
        XCTAssertTrue(diagnostics.unmappedServoAddresses.isEmpty)
    }

    func testLaterMappingSlotsAndDuplicateAddressesDoNotInventServoCounts() throws {
        var first = Array(repeating: UInt8(0), count: 16)
        first[0] = 1
        var mapping = Array(repeating: UInt8(0xFF), count: 16)
        mapping[9] = 0; mapping[10] = 0
        let zeros = Array(repeating: UInt8(0), count: 16)
        let diagnostics = try XCTUnwrap(RobotDiagnostics(firstBank: first, secondBank: zeros, mapping: mapping, modes: zeros))
        XCTAssertEqual(diagnostics.servoCount, 1)
        XCTAssertTrue(diagnostics.firstEightMappedServoSlots.isEmpty)
        XCTAssertEqual(diagnostics.mappedSlots.filter(\.isConfiguredServo).map(\.slotIndex), [9, 10])
        XCTAssertTrue(diagnostics.unmappedServoAddresses.isEmpty)
    }

    func testEverySnapshotComponentRequiresExactlySixteenEntries() {
        let valid = Array(repeating: UInt8(0), count: 16)
        for count in [0, 1, 15, 17, 32] {
            let invalid = Array(repeating: UInt8(0), count: count)
            XCTAssertNil(RobotDiagnostics(firstBank: invalid, secondBank: valid, mapping: valid, modes: valid))
            XCTAssertNil(RobotDiagnostics(firstBank: valid, secondBank: invalid, mapping: valid, modes: valid))
            XCTAssertNil(RobotDiagnostics(firstBank: valid, secondBank: valid, mapping: invalid, modes: valid))
            XCTAssertNil(RobotDiagnostics(firstBank: valid, secondBank: valid, mapping: valid, modes: invalid))
        }
    }

    func testDiagnosticFramesRejectTruncationExtraBytesAndChecksumCorruption() {
        for fixture in [firstBankReply, secondBankReply, mappingReply, modesReply] {
            for size in 0..<20 { XCTAssertNil(MeccanoidPacket.decode(fixture.prefix(size))) }
            XCTAssertNil(MeccanoidPacket.decode(fixture + Data([0])))
            for index in 0..<20 {
                var corrupted = fixture
                corrupted[index] ^= 1
                XCTAssertNil(MeccanoidPacket.decode(corrupted), "Corruption at byte \(index)")
            }
        }
    }

    func testDiagnosticDecodeHandlesNonzeroDataStartIndex() {
        let prefixed = Data([0xFF]) + firstBankReply
        let slice = prefixed.dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        XCTAssertEqual(MeccanoidPacket.decode(slice), MeccanoidPacket.decode(firstBankReply))
    }
}
