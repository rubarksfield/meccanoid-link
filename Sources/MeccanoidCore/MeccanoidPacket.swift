import Foundation

public enum MeccanoidPacketError: Error, Equatable, Sendable, LocalizedError {
    case outOfRange(parameter: String, value: Int, minimum: Int, maximum: Int)
    case unsupportedServoMode(Int)
    case invalidPoseCount(Int)

    public var errorDescription: String? {
        switch self {
        case let .outOfRange(parameter, value, minimum, maximum):
            return "\(parameter) must be between \(minimum) and \(maximum); received \(value)."
        case let .unsupportedServoMode(mode):
            return "Servo mode must be 2 (control) or 4 (read); received \(mode)."
        case let .invalidPoseCount(count):
            return "A pose must contain all eight raw servo slots; received \(count)."
        }
    }
}

/// Stock MeccaBrain BLE frames, not the serial Smart Module protocol.
///
/// Wire format is documented by Robot club (Chris Nesbitt-Smith, MIT), pymecca,
/// and independent static inspection of the original Android app. See
/// THIRD_PARTY_NOTICES.md for source attribution and evidence boundaries.
public enum MeccanoidPacket {
    public static func pin() -> Data {
        frame(command: 0x1A, payload: [1, 0, 1])
    }

    public static func status() -> Data {
        frame(command: 0x01)
    }

    public static func zeroWheels() -> Data {
        frame(command: 0x0D, payload: [2, 2, 0, 0, 255, 255])
    }

    public static func readPose() -> Data {
        frame(command: 0x09)
    }

    /// Preset 8 is STOP in the community-tested G15KS firmware bank.
    /// This is a firmware-specific request, not a guaranteed emergency stop.
    public static func stopPreset() -> Data {
        frame(command: 0x19, payload: [8, 0])
    }

    public static func eyes(red: Int, green: Int, blue: Int) throws -> Data {
        try require(red, in: 0...7, parameter: "Red")
        try require(green, in: 0...7, parameter: "Green")
        try require(blue, in: 0...7, parameter: "Blue")
        return frame(command: 0x11, payload: [0, 0, UInt8((green << 3) | red), UInt8(blue)])
    }

    /// Raw signed PWM values, deliberately limited to ±100, not percentages.
    /// Positive values request forward motion; negative values request reverse.
    /// The caller controls duration and must send an explicit stop.
    public static func wheels(left: Int, right: Int) throws -> Data {
        try require(left, in: -100...100, parameter: "Left wheel PWM")
        try require(right, in: -100...100, parameter: "Right wheel PWM")
        return frame(command: 0x0D, payload: [
            left > 0 ? 1 : 2,
            right > 0 ? 1 : 2,
            UInt8(abs(left)),
            UInt8(abs(right)),
            255, 255
        ])
    }

    public static func servoMode(_ mode: Int) throws -> Data {
        guard mode == 2 || mode == 4 else {
            throw MeccanoidPacketError.unsupportedServoMode(mode)
        }
        return frame(command: 0x0B, payload: Array(repeating: UInt8(mode), count: 16))
    }

    /// Encodes every raw slot, preserving control of unselected joints.
    /// Hardware-specific joint limits belong in the caller's calibration layer.
    public static func pose(_ positions: [UInt8]) throws -> Data {
        guard positions.count == 8 else {
            throw MeccanoidPacketError.invalidPoseCount(positions.count)
        }
        return frame(command: 0x08, payload: positions + Array(repeating: 1, count: 9))
    }

    /// Decodes only a complete, checksummed frame. A valid frame does not prove
    /// physical movement or that the reported modules match the user's assembly.
    public static func decode(_ data: Data) -> RobotReply? {
        guard data.count == 20 else { return nil }
        // Copy to a zero-based array: Data slices may have nonzero startIndex.
        let bytes = Array(data)
        let expected = Int(bytes[18]) << 8 | Int(bytes[19])
        guard bytes.prefix(18).reduce(0, { $0 + Int($1) }) == expected else { return nil }

        switch bytes[0] {
        case 0x1A:
            // The original app rejects this exact reply prefix. The transport
            // must only accept PIN replies while awaiting the handshake.
            return .pin(accepted: Array(bytes[1...3]) != [0, 1, 255])
        case 0x01:
            return .status(RobotStatus(
                buttons: RobotButtons(bitfield: bytes[8]),
                chestLEDs: bytes[9],
                motorCurrentCode: bytes[10],
                servoCurrentCode: bytes[11],
                batteryCode: bytes[12],
                limCount: bytes[13],
                presetCount: bytes[14],
                errorCode: bytes[16],
                raw: bytes
            ))
        case 0x09:
            return .pose(Array(bytes[1...8]))
        default:
            return .other(command: bytes[0], payload: Array(bytes[1...17]))
        }
    }

    private static func require(_ value: Int, in range: ClosedRange<Int>, parameter: String) throws {
        guard range.contains(value) else {
            throw MeccanoidPacketError.outOfRange(
                parameter: parameter, value: value, minimum: range.lowerBound, maximum: range.upperBound
            )
        }
    }

    private static func frame(command: UInt8, payload: [UInt8] = []) -> Data {
        precondition(payload.count <= 17)
        var bytes = [command] + payload
        bytes += Array(repeating: 0, count: 18 - bytes.count)
        let checksum = bytes.reduce(0, { $0 + Int($1) })
        bytes += [UInt8(checksum >> 8), UInt8(checksum & 0xFF)]
        return Data(bytes)
    }
}
