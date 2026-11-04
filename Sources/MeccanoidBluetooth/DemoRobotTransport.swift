import Foundation
import MeccanoidCore

/// Explicit practice mode. Never constructs CoreBluetooth objects.
@MainActor
final class DemoRobotTransport: RobotTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var connected = false
    private var pose = Array(repeating: UInt8(128), count: 8)

    func startScan() {
        onEvent?(.bluetooth("Practice mode · no Bluetooth"))
        onEvent?(.discovered(DiscoveredRobot(id: id, name: "Practice robot", rssi: -42)))
    }
    func stopScan() {}
    func connect(to id: UUID) {
        guard id == self.id else { return }
        connected = true; onEvent?(.connected); onEvent?(.subscribed)
    }
    func send(_ data: Data, notAfter: ContinuousClock.Instant?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard connected else { completion(.failure(LinkError(message: "Practice robot disconnected"))); return }
        if let notAfter, ContinuousClock().now >= notAfter {
            completion(.failure(LinkError(message: "Command expired before practice transport could send it.")))
            return
        }
        completion(.success(()))
        switch data.first {
        case 0x1a: onEvent?(.received(MeccanoidPacket.pin()))
        case 0x01: onEvent?(.received(frame(1, payload: [])))
        case 0x09: onEvent?(.received(frame(9, payload: pose)))
        case 0x08: pose = Array(data.dropFirst().prefix(8))
        default: break
        }
    }
    func cancelPendingWrites() {}
    func disconnect() {
        guard connected else { return }; connected = false; onEvent?(.disconnected(nil))
    }
    private func frame(_ command: UInt8, payload: [UInt8]) -> Data {
        var bytes = [command] + payload + Array(repeating: UInt8(0), count: 17 - payload.count)
        let sum = bytes.reduce(0) { $0 + Int($1) }
        bytes += [UInt8(sum >> 8), UInt8(sum & 255)]
        return Data(bytes)
    }
}
