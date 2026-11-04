import Foundation
import XCTest
import MeccanoidCore
@testable import MeccanoidBluetooth

/// Models writes already handed to a transport whose completion can arrive late.
/// cancelPendingWrites records cancellation but cannot recall those writes.
@MainActor
private final class FakeTransport: RobotTransport {
    var onEvent: ((TransportEvent) -> Void)?
    var writes: [Data] = []
    var heldCompletions: [(Result<Void, Error>) -> Void] = []
    var completesImmediately = true
    var failHeldWritesOnCancellation = false
    var scanCount = 0
    var stopScanCount = 0
    var connectIDs: [UUID] = []
    var disconnectCount = 0
    var cancellationCount = 0

    func startScan() { scanCount += 1 }
    func stopScan() { stopScanCount += 1 }
    func connect(to id: UUID) { connectIDs.append(id) }
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        writes.append(data)
        if completesImmediately { completion(.success(())) }
        else { heldCompletions.append(completion) }
    }
    func cancelPendingWrites() {
        cancellationCount += 1
        if failHeldWritesOnCancellation {
            let cancelled = heldCompletions
            heldCompletions.removeAll()
            cancelled.forEach { $0(.failure(LinkError(message: "Command cancelled"))) }
        }
    }
    func disconnect() { disconnectCount += 1 }
    func emit(_ event: TransportEvent) { onEvent?(event) }
    func completeNext(_ result: Result<Void, Error> = .success(())) {
        precondition(!heldCompletions.isEmpty)
        heldCompletions.removeFirst()(result)
    }
}

@MainActor
private final class TestClock {
    var value = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { value.addTimeInterval(seconds) }
}

@MainActor
final class RobotControllerTests: XCTestCase {
    func testPracticeModeScanConnectConfirmNudgeAndStopWithoutHardware() async throws {
        // Exercise the same public initializer and synchronous demo event flow
        // used by the --demo app, rather than the independently faked transport.
        let controller = RobotController(demo: true)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.bluetoothStatus.contains("Practice mode"))

        controller.startScan()
        XCTAssertEqual(controller.phase, .scanning)
        XCTAssertEqual(controller.devices.count, 1)
        let device = try XCTUnwrap(controller.devices.first)
        XCTAssertEqual(device.name, "Practice robot")

        controller.connect(to: device.id)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.connectedName, "Practice robot")
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertNotNil(controller.robotStatus)

        controller.setEyes(red: 7, green: 0, blue: 0, name: "Red")
        XCTAssertEqual(controller.lastEyeColor, "Red")
        XCTAssertFalse(controller.eyesConfirmed)
        controller.confirmEyes()
        controller.setMotionEnabled(true)
        XCTAssertTrue(controller.motionEnabled)
        XCTAssertEqual(controller.positions, Array(repeating: 128, count: 8))

        controller.jog(slot: 2, delta: 3)
        XCTAssertTrue(controller.motionBusy)
        controller.refreshPose()
        XCTAssertEqual(controller.positions, [128, 128, 131, 128, 128, 128, 128, 128])

        controller.stop()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.motionBusy)
        controller.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.connectedName)
        XCTAssertFalse(controller.eyesConfirmed)
    }

    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    private var acceptedPin: Data {
        data("1a 01 00 01 00 ff ff ff ff ff ff ff ff ff ff ff ff ff 0d 0f")
    }

    private var statusReply: Data {
        data("01 04 00 01 0a 07 00 00 00 00 07 72 04 00 14 00 00 00 00 a8")
    }

    private func poseReply(_ positions: [UInt8]) -> Data {
        precondition(positions.count == 8)
        var bytes: [UInt8] = [9] + positions + Array(repeating: 0, count: 9)
        let sum = bytes.reduce(0) { $0 + Int($1) }
        bytes += [UInt8(sum >> 8), UInt8(sum & 255)]
        return Data(bytes)
    }

    private func connecting(_ transport: FakeTransport, clock: TestClock? = nil) -> RobotController {
        let clock = clock ?? TestClock()
        let controller = RobotController(transport: transport, now: { clock.value })
        let device = DiscoveredRobot(id: UUID(), name: "MECCANOID TEST", rssi: -45)
        controller.startScan()
        transport.emit(.discovered(device))
        controller.connect(to: device.id)
        transport.emit(.connected)
        transport.emit(.subscribed)
        return controller
    }

    private func ready(_ transport: FakeTransport, clock: TestClock? = nil) -> RobotController {
        let controller = connecting(transport, clock: clock)
        transport.emit(.received(acceptedPin))
        XCTAssertEqual(controller.phase, .ready)
        return controller
    }

    private func enable(_ controller: RobotController, transport: FakeTransport) {
        controller.setEyes(red: 7, green: 0, blue: 0, name: "Red")
        controller.confirmEyes()
        controller.setMotionEnabled(true)
        // Complete the initial read requested when movement is enabled.
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertTrue(controller.motionEnabled)
    }

    func testConstructionDoesNotScanOrConnect() async {
        let transport = FakeTransport()
        let controller = RobotController(transport: transport)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(transport.scanCount, 0)
        XCTAssertTrue(transport.connectIDs.isEmpty)
        XCTAssertTrue(transport.writes.isEmpty)
        controller.confirmEyes()
        controller.setMotionEnabled(true)
        XCTAssertFalse(controller.motionEnabled)
    }

    func testConnectAuthenticatesAndStopsWheelsWithoutAutomaticMotion() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        XCTAssertEqual(transport.writes, [MeccanoidPacket.pin(), MeccanoidPacket.zeroWheels(), MeccanoidPacket.status()])
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.eyesConfirmed)
        XCTAssertNil(controller.positions)
        transport.emit(.received(acceptedPin))
        XCTAssertEqual(transport.writes.count, 3, "Duplicate PIN reply must not repeat startup actions")
    }

    func testFailureClearsStaleRowsAndRequiresFreshDiscoveryForRetry() async {
        let transport = FakeTransport()
        let controller = connecting(transport)
        let staleDevice = controller.devices[0]
        transport.emit(.failed("Connection failed"))
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.devices.isEmpty)
        transport.emit(.discovered(staleDevice))
        XCTAssertTrue(controller.devices.isEmpty, "Late scan events must not restore stale retry rows")
        controller.connect(to: staleDevice.id)
        XCTAssertEqual(transport.connectIDs.count, 1)

        controller.startScan()
        XCTAssertEqual(controller.phase, .scanning)
        XCTAssertNil(controller.errorMessage)
        transport.emit(.discovered(staleDevice))
        controller.connect(to: staleDevice.id)
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertEqual(transport.connectIDs, [staleDevice.id, staleDevice.id])
        transport.emit(.disconnected(nil))
    }

    func testConnectingTimeoutGivesPowerAndRescanAdviceWithoutYellowButton() async {
        let transport = FakeTransport()
        let controller = RobotController(transport: transport)
        let device = DiscoveredRobot(id: UUID(), name: "MECCANOID TEST", rssi: -45)
        controller.startScan()
        transport.emit(.discovered(device))
        controller.connect(to: device.id)
        controller.connectionTimedOut()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.devices.isEmpty)
        XCTAssertTrue(controller.errorMessage?.contains("power") == true)
        XCTAssertTrue(controller.errorMessage?.contains("scan again") == true)
        XCTAssertFalse(controller.errorMessage?.contains("yellow") == true)
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testHandshakeTimeoutMentionsTheRobotConfirmationButton() async {
        let transport = FakeTransport()
        let controller = connecting(transport)
        XCTAssertEqual(controller.phase, .handshaking)
        controller.connectionTimedOut()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.devices.isEmpty)
        XCTAssertTrue(controller.errorMessage?.contains("yellow button") == true)
        XCTAssertTrue(controller.errorMessage?.contains("scan again") == true)
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testExpiredConnectionDeadlineDoesNotFailAReadySession() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        controller.connectionTimedOut()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(transport.disconnectCount, 0)
    }

    func testConnectedCallbackLogsBluetoothProgressBeforeHandshake() async {
        let transport = FakeTransport()
        let controller = RobotController(transport: transport)
        let device = DiscoveredRobot(id: UUID(), name: "MECCANOID TEST", rssi: -45)
        controller.startScan()
        transport.emit(.discovered(device))
        controller.connect(to: device.id)
        XCTAssertFalse(controller.logs.contains { $0.contains("Bluetooth connected") })
        transport.emit(.connected)
        XCTAssertTrue(controller.logs.contains("Bluetooth connected; discovering robot controls"))
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertTrue(transport.writes.isEmpty, "A link connection alone must not send the PIN or enable controls")
        XCTAssertFalse(controller.isConnected)
        transport.emit(.disconnected(nil))
    }

    func testHandshakeRequiresValidPinResponseAndHandlesExplicitRejection() async {
        let transport = FakeTransport()
        let controller = connecting(transport)
        transport.emit(.received(Data([0x1a, 1])))
        var badChecksum = acceptedPin; badChecksum[19] ^= 1
        transport.emit(.received(badChecksum))
        transport.emit(.received(statusReply))
        XCTAssertEqual(controller.phase, .handshaking)
        XCTAssertEqual(transport.writes, [MeccanoidPacket.pin()])
        transport.emit(.received(data("1a 00 01 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 1a")))
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertTrue(controller.errorMessage?.contains("declined") == true)
    }

    func testEyeCommandAcceptanceDoesNotClaimPhysicalConfirmation() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        controller.confirmEyes()
        controller.setMotionEnabled(true)
        XCTAssertFalse(controller.motionEnabled)
        controller.setEyes(red: 7, green: 0, blue: 0, name: "Red")
        XCTAssertEqual(controller.lastEyeColor, "Red")
        XCTAssertFalse(controller.eyesConfirmed)
        controller.setMotionEnabled(true)
        XCTAssertFalse(controller.motionEnabled)
        controller.confirmEyes()
        controller.setMotionEnabled(true)
        XCTAssertTrue(controller.motionEnabled)
        XCTAssertEqual(transport.writes.last, MeccanoidPacket.readPose())
        XCTAssertFalse(transport.writes.contains { $0.first == 8 || $0.first == 0x0b })
    }

    func testDisconnectClearsConfirmationAndLateWriteCannotRestoreIt() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        enable(controller, transport: transport)
        transport.completesImmediately = false
        controller.setEyes(red: 0, green: 7, blue: 0, name: "Green")
        transport.emit(.disconnected("Connection lost"))
        transport.completeNext()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.eyesConfirmed)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertNil(controller.lastEyeColor)
        XCTAssertNil(controller.positions)
        controller.confirmEyes()
        XCTAssertFalse(controller.eyesConfirmed)
    }

    func testUnconfirmedMotionDoesNotWriteAnyActuatorCommand() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        transport.writes.removeAll()
        controller.drive(left: 40, right: 40)
        controller.jog(slot: 0, delta: 3)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertFalse(controller.motionBusy)
    }

    func testJogIgnoresStalePoseUntilPostModeSampleIsRequested() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.writes.removeAll()
        transport.completesImmediately = false
        controller.jog(slot: 1, delta: 3)
        XCTAssertEqual(transport.writes, [try MeccanoidPacket.servoMode(2)])
        transport.emit(.received(poseReply([90, 91, 92, 93, 94, 95, 96, 97])))
        XCTAssertFalse(transport.writes.contains { $0.first == 8 }, "A reply from an older request must not trigger movement")
        transport.completeNext() // The mode write is now accepted.
        XCTAssertEqual(transport.writes.last, MeccanoidPacket.readPose())
        let fresh: [UInt8] = [100, 110, 120, 130, 140, 150, 160, 170]
        transport.emit(.received(poseReply(fresh)))
        XCTAssertEqual(transport.writes.last, try MeccanoidPacket.pose([100, 113, 120, 130, 140, 150, 160, 170]))
    }

    func testJogDoesNotOverlapAnOutstandingPoseRead() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.refreshPose()
        transport.writes.removeAll()
        controller.jog(slot: 0, delta: 2)
        XCTAssertFalse(transport.writes.contains { $0.first == 0x0b || $0.first == 8 }, "Finish the earlier pose read before beginning a nudge")
        XCTAssertFalse(controller.motionBusy)
    }

    func testAbsentOrOutOfRangeJogSlotNeverProducesPoseWrite() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        for (position, delta) in [(0, 1), (24, -1), (232, 1), (255, -1)] {
            transport.writes.removeAll()
            controller.jog(slot: 0, delta: delta)
            transport.emit(.received(poseReply([UInt8(position), 110, 120, 130, 140, 150, 160, 170])))
            XCTAssertFalse(transport.writes.contains { $0.first == 8 })
            XCTAssertFalse(controller.motionBusy)
        }
    }

    func testInvalidJogArgumentsCannotEnterBusyState() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.writes.removeAll()
        for (slot, delta) in [(-1, 1), (8, 1), (0, -4), (0, 4), (0, 0)] {
            controller.jog(slot: slot, delta: delta)
        }
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertFalse(controller.motionBusy)
    }

    func testStopInvalidatesLateModeCompletionAndPendingJog() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.completesImmediately = false
        controller.jog(slot: 0, delta: 1)
        let cancelsBefore = transport.cancellationCount
        controller.stop()
        let countAfterStop = transport.writes.count
        transport.completeNext() // Stale successful mode write.
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertEqual(transport.writes.count, countAfterStop)
        XCTAssertFalse(transport.writes.contains { $0.first == 8 })
        XCTAssertGreaterThan(transport.cancellationCount, cancelsBefore)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.motionBusy)
        XCTAssertTrue(transport.writes.suffix(2).contains(MeccanoidPacket.zeroWheels()))
    }

    func testStopCancellationFailuresDoNotRecursivelyFailTheConnection() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.completesImmediately = false
        transport.failHeldWritesOnCancellation = true
        controller.jog(slot: 0, delta: 1)
        controller.stop()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(transport.disconnectCount, 0)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.motionBusy)
    }

    func testMissingFreshPoseTimesOutAndLateReplyCannotMoveRobot() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        enable(controller, transport: transport)
        transport.writes.removeAll()
        controller.jog(slot: 0, delta: 1)
        XCTAssertTrue(controller.motionBusy)
        try await Task.sleep(for: .milliseconds(2250))
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.eyesConfirmed)
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertTrue(controller.errorMessage?.contains("joint-position") == true)
        let count = transport.writes.count
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertEqual(transport.writes.count, count)
        XCTAssertFalse(transport.writes.contains { $0.first == 8 })
    }

    func testWheelPulseStopsAutomaticallyAndRejectsOverlap() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.writes.removeAll()
        controller.drive(left: 40, right: -40)
        controller.drive(left: -40, right: 40)
        XCTAssertEqual(transport.writes, [try MeccanoidPacket.wheels(left: 40, right: -40)])
        XCTAssertTrue(controller.motionBusy)
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(transport.writes.last, MeccanoidPacket.zeroWheels())
        XCTAssertEqual(transport.writes.filter { $0.first == 0x0d }.count, 2)
        XCTAssertFalse(controller.motionBusy)
    }

    func testWheelControllerBoundsAreStricterThanWireCodec() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.writes.removeAll()
        for invalid in [-41, 41, -100, 100, Int.min, Int.max] {
            controller.drive(left: invalid, right: 0)
            controller.drive(left: 0, right: invalid)
        }
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertFalse(controller.motionBusy)
    }

    func testStopCancelsPulseTimerAndDisablesFurtherMotion() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.drive(left: 40, right: 40)
        controller.stop()
        let count = transport.writes.count
        controller.drive(left: 40, right: 40)
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(transport.writes.count, count)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.motionBusy)
    }

    func testLatePulseWriteCompletionAfterStopCannotScheduleNewAction() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.completesImmediately = false
        controller.drive(left: 40, right: 40)
        controller.stop()
        let count = transport.writes.count
        transport.completeNext()
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(transport.writes.count, count)
        XCTAssertFalse(controller.motionBusy)
    }

    func testWriteSuccessWithoutRobotRepliesDoesNotKeepConnectionAlive() async {
        let transport = FakeTransport()
        let clock = TestClock()
        let controller = ready(transport, clock: clock)
        enable(controller, transport: transport)
        clock.advance(4)
        controller.checkHeartbeat() // Transport accepts this write; robot is silent.
        XCTAssertEqual(controller.phase, .ready)
        clock.advance(2)
        controller.checkHeartbeat()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.eyesConfirmed)
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertTrue(controller.errorMessage?.contains("stopped replying") == true)
    }

    func testStopCancellingHeartbeatAllowsTheNextHeartbeatToBeSent() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        transport.completesImmediately = false
        transport.failHeldWritesOnCancellation = true
        controller.checkHeartbeat()
        XCTAssertEqual(transport.writes.last, MeccanoidPacket.status())
        controller.stop()
        let before = transport.writes.count
        controller.checkHeartbeat()
        XCTAssertEqual(transport.writes.count, before + 1)
        XCTAssertEqual(transport.writes.last, MeccanoidPacket.status())
        XCTAssertEqual(controller.phase, .ready)
    }

    func testDisconnectCancelsPoseDeadlineAndIgnoresLatePose() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        controller.setEyes(red: 7, green: 0, blue: 0, name: "Red")
        controller.confirmEyes()
        controller.setMotionEnabled(true) // Its pose request receives no reply.
        controller.disconnect()
        try await Task.sleep(for: .milliseconds(2250))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertNil(controller.errorMessage)
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertNil(controller.positions)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(transport.writes.contains { $0.first == 8 })
    }

    func testMalformedRepliesDoNotRefreshLivenessButValidRepliesDo() async {
        let transport = FakeTransport()
        let clock = TestClock()
        let controller = ready(transport, clock: clock)
        clock.advance(4)
        transport.emit(.received(statusReply))
        clock.advance(4)
        controller.checkHeartbeat()
        XCTAssertEqual(controller.phase, .ready)
        var corrupt = statusReply; corrupt[19] ^= 1
        transport.emit(.received(corrupt))
        clock.advance(2)
        controller.checkHeartbeat()
        XCTAssertEqual(controller.phase, .failed)
    }

    func testTransportWriteFailureClearsGatesAndDoesNotClaimEyeCommandSent() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        transport.completesImmediately = false
        controller.setEyes(red: 7, green: 0, blue: 0, name: "Red")
        transport.completeNext(.failure(LinkError(message: "Test write failure")))
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertNil(controller.lastEyeColor)
        XCTAssertFalse(controller.eyesConfirmed)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertEqual(controller.errorMessage, "Test write failure")
    }

    func testInactiveAppStopsEnabledMotion() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.appBecameInactive()
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertTrue(transport.writes.suffix(2).contains(MeccanoidPacket.zeroWheels()))
    }
}
