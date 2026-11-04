import Foundation

public struct DiscoveredRobot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public init(id: UUID, name: String, rssi: Int) {
        self.id = id; self.name = name; self.rssi = rssi
    }
}

public enum ConnectionPhase: String, Equatable, Sendable {
    case idle, scanning, connecting, handshaking, ready, failed
}

enum TransportEvent {
    case bluetooth(String)
    case discovered(DiscoveredRobot)
    case connected
    case subscribed
    case received(Data)
    case disconnected(String?)
    case failed(String)
}

struct LinkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Implementations deliver events and write completions on the main actor.
@MainActor
protocol RobotTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func startScan()
    func stopScan()
    func connect(to id: UUID)
    /// Reject an expired command before handing it to the platform. A command
    /// already handed to CoreBluetooth cannot be recalled by this deadline.
    func send(_ data: Data, notAfter: ContinuousClock.Instant?, completion: @escaping (Result<Void, Error>) -> Void)
    func cancelPendingWrites()
    func disconnect()
}

extension RobotTransport {
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        send(data, notAfter: nil, completion: completion)
    }
}
