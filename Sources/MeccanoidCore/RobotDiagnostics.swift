import Foundation

/// Read-only module inventory banks. Each bank contains four channels with four
/// daisy-chain positions per channel, in channel-major order.
public enum RobotModuleBank: UInt8, CaseIterable, Sendable {
    case channels1to4 = 0x02
    case channels5to8 = 0x03
}

/// A reported Smart Module address, not a physical/anatomical joint identity.
public struct RobotModuleAddress: Hashable, Sendable {
    public let rawValue: UInt8
    public var channelIndex: Int { Int(rawValue >> 4) }
    public var positionIndex: Int { Int(rawValue & 0x0F) }
    public var displayName: String {
        "Channel \(channelIndex + 1), position \(positionIndex + 1)"
    }

    public init?(rawValue: UInt8) {
        guard rawValue >> 4 < 8, rawValue & 0x0F < 4 else { return nil }
        self.rawValue = rawValue
    }
}

public struct RobotModule: Equatable, Sendable {
    public let address: RobotModuleAddress
    /// Unknown firmware codes are preserved rather than treated as empty slots.
    public let typeCode: UInt8
    public var isServo: Bool { typeCode == 1 }
    public var typeDescription: String { Self.describe(typeCode) }

    fileprivate static func describe(_ code: UInt8) -> String {
        switch code {
        case 0: return "No module reported"
        case 1: return "Servo"
        case 2: return "LED"
        case 3: return "Roller"
        default: return String(format: "Unknown type (0x%02X)", code)
        }
    }
}

/// A mapping slot joins a reported address to the inventory. It does not imply
/// that movement commands work or that the module has been mechanically tested.
public struct RobotMappedSlot: Equatable, Sendable {
    public let slotIndex: Int
    public let rawAddress: UInt8
    public let address: RobotModuleAddress?
    public let moduleTypeCode: UInt8?
    /// Raw status only. Do not infer torque, position or successful control.
    public let modeCode: UInt8
    public var isConfiguredServo: Bool { moduleTypeCode == 1 }
    public var summary: String {
        if rawAddress == 0xFF { return "Unassigned (0xFF)" }
        guard let address, let moduleTypeCode else {
            return String(format: "Unknown address (0x%02X)", rawAddress)
        }
        return "\(address.displayName): \(RobotModule.describe(moduleTypeCode))"
    }
}

/// One complete read-only snapshot. Callers should assemble it from the current
/// connection and discard incomplete/stale sessions rather than merge robots.
public struct RobotDiagnostics: Equatable, Sendable {
    public let firstBank: [UInt8]
    public let secondBank: [UInt8]
    public let mapping: [UInt8]
    public let modes: [UInt8]

    public init?(firstBank: [UInt8], secondBank: [UInt8], mapping: [UInt8], modes: [UInt8]) {
        guard firstBank.count == 16, secondBank.count == 16,
              mapping.count == 16, modes.count == 16 else { return nil }
        self.firstBank = firstBank
        self.secondBank = secondBank
        self.mapping = mapping
        self.modes = modes
    }

    /// All 32 reported channel positions, including empty and unknown types.
    public var modules: [RobotModule] {
        (firstBank + secondBank).enumerated().map { index, code in
            // Indices 0...31 construct only the verified address space.
            let raw = UInt8(((index / 4) << 4) | (index % 4))
            return RobotModule(address: RobotModuleAddress(rawValue: raw)!, typeCode: code)
        }
    }

    public var servoCount: Int { modules.filter(\.isServo).count }

    public var mappedSlots: [RobotMappedSlot] {
        let inventory = firstBank + secondBank
        return mapping.enumerated().map { slot, raw in
            let address = RobotModuleAddress(rawValue: raw)
            let typeCode = address.map { inventory[$0.channelIndex * 4 + $0.positionIndex] }
            return RobotMappedSlot(
                slotIndex: slot, rawAddress: raw, address: address,
                moduleTypeCode: typeCode, modeCode: modes[slot]
            )
        }
    }

    /// Display information only; this is not authorization to move these slots.
    public var firstEightMappedServoSlots: [RobotMappedSlot] {
        mappedSlots.prefix(8).filter(\.isConfiguredServo)
    }

    /// Configured servos absent from all sixteen reported mapping entries.
    public var unmappedServoAddresses: [RobotModuleAddress] {
        let assigned = Set(mapping.compactMap(RobotModuleAddress.init(rawValue:)))
        return modules.filter { $0.isServo && !assigned.contains($0.address) }.map(\.address)
    }
}
