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
    var transmitted: [(data: Data, at: ContinuousClock.Instant, notAfter: ContinuousClock.Instant?)] = []
    var queued: [(data: Data, notAfter: ContinuousClock.Instant?, completion: (Result<Void, Error>) -> Void)] = []
    var queuesWrites = false
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
    func send(_ data: Data, notAfter: ContinuousClock.Instant?, completion: @escaping (Result<Void, Error>) -> Void) {
        writes.append(data)
        if queuesWrites {
            queued.append((data, notAfter, completion))
            return
        }
        transmit(data, notAfter: notAfter, completion: completion)
    }
    private func transmit(_ data: Data, notAfter: ContinuousClock.Instant?, completion: @escaping (Result<Void, Error>) -> Void) {
        let instant = ContinuousClock.now
        if let notAfter, instant >= notAfter {
            completion(.failure(LinkError(message: "Command expired before transmission")))
            return
        }
        transmitted.append((data, instant, notAfter))
        if completesImmediately { completion(.success(())) }
        else { heldCompletions.append(completion) }
    }
    func drainQueuedWrites() {
        while !queued.isEmpty {
            let next = queued.removeFirst()
            transmit(next.data, notAfter: next.notAfter, completion: next.completion)
        }
    }
    func cancelPendingWrites() {
        cancellationCount += 1
        let cancelledQueue = queued
        queued.removeAll()
        cancelledQueue.forEach { $0.completion(.failure(LinkError(message: "Command cancelled"))) }
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
        // A manual read cannot interfere with the bounded refresh or its final
        // readback. Wait for the public operation to finish using the real demo.
        controller.refreshPose()
        XCTAssertEqual(controller.positions, Array(repeating: 128, count: 8))
        let finished = await waitUntil { !controller.motionBusy }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.positions, [128, 128, 131, 128, 128, 128, 128, 128])
        XCTAssertFalse(controller.motionBusy)

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

    // Anonymized replies from the four-servo hardware pilot. No guessed pose or
    // module writes are needed to discover the incomplete returned mapping.
    private var layoutReplies: [Data] {
        [
            data("02 01 01 00 00 02 00 00 00 01 00 00 00 01 00 00 00 00 00 08"),
            data("03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03"),
            data("20 22 21 20 00 01 02 10 11 ff ff ff ff ff ff ff ff 00 08 9f"),
            data("0a 00 00 04 04 04 00 00 00 00 00 00 00 00 00 00 00 00 00 16")
        ]
    }

    func testLayoutReadIsSerialAndOnlyReadsUntilCompleteSnapshot() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        let start = transport.writes.count
        controller.inspectRobot()
        XCTAssertTrue(controller.diagnosticsBusy)
        XCTAssertNil(controller.diagnostics)
        XCTAssertEqual(transport.writes.count, start + 1)
        controller.inspectRobot()
        XCTAssertEqual(transport.writes.count, start + 1, "Duplicate reads must not overlap")
        // Neither an unsolicited later reply nor malformed expected data should
        // complete a stage or seed the snapshot.
        transport.emit(.received(layoutReplies[2]))
        transport.emit(.received(layoutReplies[0].dropLast()))
        XCTAssertEqual(transport.writes.count, start + 1)
        for (index, reply) in layoutReplies.enumerated() {
            transport.emit(.received(reply))
            XCTAssertEqual(transport.writes.count, start + min(index + 2, 4))
            if index < 3 { XCTAssertNil(controller.diagnostics) }
        }
        XCTAssertEqual(Array(transport.writes.dropFirst(start)), [
            MeccanoidPacket.readModules(.channels1to4), MeccanoidPacket.readModules(.channels5to8),
            MeccanoidPacket.readServoMapping(), MeccanoidPacket.readServoModes()
        ])
        let snapshot = try XCTUnwrap(controller.diagnostics)
        XCTAssertEqual(snapshot.servoCount, 4)
        XCTAssertEqual(snapshot.firstEightMappedServoSlots.map(\.slotIndex), [2, 3, 4])
        XCTAssertEqual(snapshot.unmappedServoAddresses.map(\.rawValue), [0x30])
        XCTAssertFalse(controller.diagnosticsBusy)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertNil(controller.positions)
    }

    func testLayoutReadCannotStartDisconnectedOrWithMovementEnabled() async {
        let transport = FakeTransport()
        let disconnected = RobotController(transport: transport)
        disconnected.inspectRobot()
        XCTAssertTrue(transport.writes.isEmpty)
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        let count = transport.writes.count
        controller.inspectRobot()
        XCTAssertFalse(controller.diagnosticsBusy)
        XCTAssertEqual(transport.writes.count, count)
    }

    func testLayoutReadBlocksEnablingMotionAndStopDoesNotLoseReadObligation() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        controller.setEyes(red: 0, green: 0, blue: 7, name: "Blue")
        controller.confirmEyes()
        controller.inspectRobot()
        controller.stop()
        XCTAssertTrue(controller.diagnosticsBusy)
        controller.setMotionEnabled(true)
        XCTAssertFalse(controller.motionEnabled)
        for reply in layoutReplies { transport.emit(.received(reply)) }
        XCTAssertNotNil(controller.diagnostics)
        controller.setMotionEnabled(true)
        XCTAssertTrue(controller.motionEnabled)
    }

    func testLayoutTimeoutDisconnectsAndIgnoresLateReplies() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        controller.inspectRobot()
        transport.emit(.received(layoutReplies[0]))
        controller.diagnosticsTimedOut()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertFalse(controller.diagnosticsBusy)
        XCTAssertNil(controller.diagnostics)
        let count = transport.writes.count
        for reply in layoutReplies { transport.emit(.received(reply)) }
        controller.inspectRobot()
        XCTAssertEqual(transport.writes.count, count)
        XCTAssertNil(controller.diagnostics)
    }

    func testDisconnectDoesNotAdvanceLayoutReadsDuringStopGracePeriod() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        controller.inspectRobot()
        controller.disconnect()
        let count = transport.writes.count
        for reply in layoutReplies { transport.emit(.received(reply)) }
        XCTAssertEqual(transport.writes.count, count, "Disconnect must not schedule more diagnostic reads")
        XCTAssertNil(controller.diagnostics)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.diagnosticsBusy)
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testNewLayoutReadAndDisconnectClearPriorSnapshot() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        controller.inspectRobot()
        for reply in layoutReplies { transport.emit(.received(reply)) }
        XCTAssertNotNil(controller.diagnostics)
        controller.inspectRobot()
        XCTAssertNil(controller.diagnostics, "Old layout must not look like a fresh reading")
        transport.emit(.received(layoutReplies[0]))
        transport.emit(.disconnected(nil))
        XCTAssertFalse(controller.diagnosticsBusy)
        XCTAssertNil(controller.diagnostics)
        for reply in layoutReplies { transport.emit(.received(reply)) }
        XCTAssertNil(controller.diagnostics)
    }

    func testPracticeLayoutReadUsesSamePublicFlowWithoutMoving() async throws {
        let controller = RobotController(demo: true)
        controller.startScan()
        controller.connect(to: try XCTUnwrap(controller.devices.first).id)
        controller.refreshPose()
        let before = controller.positions
        controller.inspectRobot()
        let snapshot = try XCTUnwrap(controller.diagnostics)
        XCTAssertEqual(snapshot.servoCount, 8)
        XCTAssertTrue(snapshot.unmappedServoAddresses.isEmpty)
        XCTAssertEqual(snapshot.firstEightMappedServoSlots.count, 8)
        XCTAssertEqual(Array(snapshot.modes.prefix(8)), Array(repeating: 4, count: 8))
        controller.refreshPose()
        XCTAssertEqual(controller.positions, before)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertFalse(controller.diagnosticsBusy)
        controller.disconnect()
    }

    private func poseReply(_ positions: [UInt8]) -> Data {
        precondition(positions.count == 8)
        var bytes: [UInt8] = [9] + positions + Array(repeating: 0, count: 9)
        let sum = bytes.reduce(0) { $0 + Int($1) }
        bytes += [UInt8(sum >> 8), UInt8(sum & 255)]
        return Data(bytes)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Deliberately prevents the actor's expiry Task from running. A queued
    /// transport must still enforce each packet's deadline when it becomes ready.
    private func stallActorForDeadlineTest() {
        Thread.sleep(forTimeInterval: 1.05)
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

    func testJogRefreshRepeatsOneFrozenTargetAndWaitsForFinalReadback() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        transport.writes.removeAll(); transport.transmitted.removeAll()
        controller.jog(slot: 2, delta: 3)
        let baseline: [UInt8] = [90, 100, 110, 120, 130, 140, 150, 160]
        transport.emit(.received(poseReply(baseline)))
        let countBeforeManualRead = transport.writes.count
        controller.refreshPose()
        XCTAssertEqual(transport.writes.count, countBeforeManualRead)
        let finalReadRequested = await waitUntil {
            transport.writes.filter { $0.first == 9 }.count == 2
        }
        XCTAssertTrue(finalReadRequested)
        let frames = transport.transmitted.filter { $0.data.first == 8 }
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertLessThanOrEqual(frames.count, 10)
        let expected = try MeccanoidPacket.pose([90, 100, 113, 120, 130, 140, 150, 160])
        XCTAssertTrue(frames.allSatisfy { $0.data == expected }, "The delta must never accumulate across repeated packets")
        let expiry = try XCTUnwrap(frames.first?.notAfter)
        XCTAssertTrue(frames.allSatisfy { $0.notAfter == expiry && $0.at < expiry })
        XCTAssertTrue(controller.motionBusy, "Remain busy until final position feedback arrives")
        transport.emit(.received(poseReply([90, 100, 112, 120, 130, 140, 150, 160])))
        XCTAssertFalse(controller.motionBusy)
        XCTAssertEqual(controller.positions?[2], 112, "Show measured feedback, not the requested target")
        XCTAssertTrue(controller.logs.contains { $0.contains("110 → 113") })
    }

    func testJogRefreshBackpressureAndLateCompletionCannotExtendDeadline() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.completesImmediately = false
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(transport.writes.filter { $0.first == 8 }.count, 1, "Never queue behind an outstanding pose")
        let firstAcceptedAt = ContinuousClock.now
        transport.completeNext()
        let secondFrame = await waitUntil(timeout: .milliseconds(300)) {
            transport.writes.filter { $0.first == 8 }.count == 2
        }
        XCTAssertTrue(secondFrame)
        let secondHandoff = try XCTUnwrap(transport.transmitted.filter { $0.data.first == 8 }.dropFirst().first)
        XCTAssertGreaterThanOrEqual(firstAcceptedAt.duration(to: secondHandoff.at), .milliseconds(100), "Wait after acceptance rather than catching up")
        let expired = await waitUntil(timeout: .seconds(2)) { controller.phase == .failed }
        XCTAssertTrue(expired)
        XCTAssertFalse(controller.motionBusy)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertEqual(transport.disconnectCount, 1)
        let count = transport.writes.count
        transport.completeNext() // Completion of a frame already handed off.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(transport.writes.count, count, "A late completion must not schedule a frame or read")
    }

    func testQueuedPoseCannotTransmitAfterDeadlineEvenBeforeExpiryTaskRuns() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.queuesWrites = true
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertEqual(transport.queued.count, 1)
        stallActorForDeadlineTest()
        transport.drainQueuedWrites() // Readiness occurs before the controller's Task can execute.
        XCTAssertFalse(transport.transmitted.contains { $0.data.first == 8 })
        XCTAssertTrue(transport.queued.isEmpty)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertFalse(controller.motionBusy)
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    func testIndependentDeadlineCancelsPoseThatNeverBecomesReady() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.queuesWrites = true
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertEqual(transport.queued.count, 1)
        let failed = await waitUntil(timeout: .seconds(2)) { controller.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(transport.queued.isEmpty, "The independent deadline must cancel an unsent pose without a readiness callback")
        XCTAssertEqual(transport.disconnectCount, 1, "Synchronous cancellation failures must not recursively fail")
        XCTAssertFalse(controller.motionBusy)
        transport.drainQueuedWrites()
        XCTAssertFalse(transport.transmitted.contains { $0.data.first == 8 })
    }

    func testStopDuringRefreshCancelsEveryLaterPoseAndSettlingRead() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        try await Task.sleep(for: .milliseconds(230))
        controller.stop()
        let poses = transport.writes.filter { $0.first == 8 }.count
        let reads = transport.writes.filter { $0.first == 9 }.count
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(transport.writes.filter { $0.first == 8 }.count, poses)
        XCTAssertEqual(transport.writes.filter { $0.first == 9 }.count, reads)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(controller.motionBusy)
    }

    func testStopPreservesOutstandingPoseReadUntilOldReplyIsDrained() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1) // Its fresh 09 request remains unanswered.
        controller.stop()
        controller.setMotionEnabled(true)
        let before = transport.writes.count
        controller.jog(slot: 0, delta: 1)
        XCTAssertEqual(transport.writes.count, before)
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertFalse(transport.writes.contains { $0.first == 8 }, "Old readback cannot execute the cancelled jog")
        controller.jog(slot: 0, delta: 1)
        XCTAssertEqual(transport.writes.last, MeccanoidPacket.readPose())
        XCTAssertFalse(transport.writes.contains { $0.first == 8 }, "A second jog must await its own fresh response")
    }

    func testStopKeepsDeadlineForAnOutstandingPoseRead() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        controller.stop()
        controller.setMotionEnabled(true)
        let failed = await waitUntil { controller.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(controller.errorMessage?.contains("joint-position") == true)
        XCTAssertFalse(controller.motionBusy)
        XCTAssertFalse(controller.motionEnabled)
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        XCTAssertFalse(transport.writes.contains { $0.first == 8 })
    }

    func testReconnectCannotReviveOldJogWriteCompletion() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.completesImmediately = false
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        transport.emit(.disconnected(nil))
        transport.completesImmediately = true
        controller.startScan()
        let nextRobot = DiscoveredRobot(id: UUID(), name: "MECCANOID RETRY", rssi: -42)
        transport.emit(.discovered(nextRobot))
        controller.connect(to: nextRobot.id)
        transport.emit(.connected); transport.emit(.subscribed)
        transport.emit(.received(acceptedPin))
        enable(controller, transport: transport)
        let count = transport.writes.count
        transport.completeNext()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(transport.writes.count, count)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(controller.motionBusy)
    }

    func testMissingFinalJogReadbackFailsAndClearsBusy() async {
        let transport = FakeTransport()
        let controller = ready(transport)
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        let failed = await waitUntil(timeout: .seconds(4)) { controller.phase == .failed }
        XCTAssertTrue(failed)
        XCTAssertFalse(controller.motionBusy)
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertTrue(controller.errorMessage?.contains("joint-position") == true)
        XCTAssertEqual(transport.disconnectCount, 1)
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

    func testInactiveAppStopsEnabledMotion() async throws {
        let transport = FakeTransport()
        let controller = ready(transport)
        defer { transport.emit(.disconnected(nil)) }
        enable(controller, transport: transport)
        controller.jog(slot: 0, delta: 1)
        transport.emit(.received(poseReply([100, 110, 120, 130, 140, 150, 160, 170])))
        controller.appBecameInactive()
        XCTAssertFalse(controller.motionEnabled)
        XCTAssertTrue(transport.writes.suffix(2).contains(MeccanoidPacket.zeroWheels()))
        let poses = transport.writes.filter { $0.first == 8 }.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(transport.writes.filter { $0.first == 8 }.count, poses)
        XCTAssertFalse(controller.motionBusy)
    }
}
