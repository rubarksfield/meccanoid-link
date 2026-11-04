import Foundation
import XCTest
import MeccanoidCore
@testable import MeccanoidBluetooth

@MainActor
final class DemoRobotTransportTests: XCTestCase {
    private func connectedTransport() throws -> DemoRobotTransport {
        let transport = DemoRobotTransport()
        var discoveredID: UUID?
        transport.onEvent = { event in
            if case .discovered(let robot) = event { discoveredID = robot.id }
        }
        transport.startScan()
        transport.connect(to: try XCTUnwrap(discoveredID))
        return transport
    }

    private func readPose(_ transport: DemoRobotTransport) throws -> [UInt8] {
        var pose: [UInt8]?
        transport.onEvent = { event in
            if case .received(let data) = event,
               let reply = MeccanoidPacket.decode(data), case .pose(let values) = reply {
                pose = values
            }
        }
        transport.send(MeccanoidPacket.readPose()) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
        }
        return try XCTUnwrap(pose)
    }

    func testExpiredPoseIsRejectedWithoutChangingPracticeRobot() throws {
        let transport = try connectedTransport()
        let target: [UInt8] = [131, 128, 128, 128, 128, 128, 128, 128]
        var rejection: Error?
        transport.send(try MeccanoidPacket.pose(target), notAfter: ContinuousClock().now) { result in
            switch result {
            case .success: XCTFail("An expired pose must not be accepted")
            case .failure(let error): rejection = error
            }
        }
        XCTAssertTrue(try XCTUnwrap(rejection).localizedDescription.contains("expired"))
        XCTAssertEqual(try readPose(transport), Array(repeating: 128, count: 8))
    }

    func testUnexpiredPoseAndLegacyNoDeadlineCallsWorkWithoutBluetooth() throws {
        let transport = try connectedTransport()
        let target: [UInt8] = [128, 128, 131, 128, 128, 128, 128, 128]
        var accepted = false
        transport.send(try MeccanoidPacket.pose(target), notAfter: ContinuousClock().now.advanced(by: .seconds(5))) { result in
            switch result {
            case .success: accepted = true
            case .failure(let error): XCTFail(error.localizedDescription)
            }
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(try readPose(transport), target)
    }
}
