import Foundation

/// The four physical chest buttons as reported by a status packet.
public struct RobotButtons: Equatable, Sendable {
    public let blue: Bool
    public let red: Bool
    public let green: Bool
    public let yellow: Bool

    public init(blue: Bool, red: Bool, green: Bool, yellow: Bool) {
        self.blue = blue
        self.red = red
        self.green = green
        self.yellow = yellow
    }

    public init(bitfield: UInt8) {
        self.init(
            blue: bitfield & 0x01 != 0,
            red: bitfield & 0x02 != 0,
            green: bitfield & 0x04 != 0,
            yellow: bitfield & 0x08 != 0
        )
    }
}

/// Raw status codes. Battery and current codes are not calibrated physical units.
public struct RobotStatus: Equatable, Sendable {
    public let buttons: RobotButtons
    public let chestLEDs: UInt8
    public let motorCurrentCode: UInt8
    public let servoCurrentCode: UInt8
    public let batteryCode: UInt8
    public let limCount: UInt8
    public let presetCount: UInt8
    public let errorCode: UInt8
    /// The complete received frame, including command and checksum.
    public let raw: [UInt8]

    public init(
        buttons: RobotButtons,
        chestLEDs: UInt8,
        motorCurrentCode: UInt8,
        servoCurrentCode: UInt8,
        batteryCode: UInt8,
        limCount: UInt8,
        presetCount: UInt8,
        errorCode: UInt8,
        raw: [UInt8]
    ) {
        self.buttons = buttons
        self.chestLEDs = chestLEDs
        self.motorCurrentCode = motorCurrentCode
        self.servoCurrentCode = servoCurrentCode
        self.batteryCode = batteryCode
        self.limCount = limCount
        self.presetCount = presetCount
        self.errorCode = errorCode
        self.raw = raw
    }
}

public enum RobotReply: Equatable, Sendable {
    case pin(accepted: Bool)
    case status(RobotStatus)
    case pose([UInt8])
    case modules(bank: RobotModuleBank, types: [UInt8])
    case servoMapping([UInt8])
    case servoModes([UInt8])
    /// The 17 payload bytes, excluding the command and checksum.
    case other(command: UInt8, payload: [UInt8])
}
