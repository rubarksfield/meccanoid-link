import Foundation
import Observation
import MeccanoidCore

@MainActor @Observable
public final class RobotController {
    public private(set) var bluetoothStatus = "Bluetooth has not been checked"
    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var statusMessage = "Power on your robot, unplug USB, then scan."
    public private(set) var devices: [DiscoveredRobot] = []
    public private(set) var connectedName: String?
    public private(set) var lastEyeColor: String?
    public private(set) var eyesConfirmed = false
    public private(set) var motionEnabled = false
    public private(set) var positions: [UInt8]?
    public private(set) var logs: [String] = []
    public private(set) var errorMessage: String?
    public private(set) var robotStatus: RobotStatus?
    public private(set) var motionBusy = false
    public private(set) var diagnostics: RobotDiagnostics?
    public private(set) var diagnosticsBusy = false
    public private(set) var diagnosticsMessage = "Read the detected modules and joint slots without moving the robot."
    public var isConnected: Bool { phase == .ready }
    public var availableJointSlots: [RobotMappedSlot] {
        diagnostics?.firstEightMappedServoSlots ?? []
    }

    @ObservationIgnored private let transport: RobotTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var poseReadTask: Task<Void, Never>?
    @ObservationIgnored private var modeReadTask: Task<Void, Never>?
    @ObservationIgnored private var modeRequestPending = false
    @ObservationIgnored private var preparedJog: PreparedJog?
    @ObservationIgnored private var jogDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var jogRefresh: JogRefresh?
    @ObservationIgnored private var jogReadback: (slot: Int, before: Int, target: Int)?
    @ObservationIgnored private var poseRequestPending = false
    @ObservationIgnored private var jogSampleRequested = false
    @ObservationIgnored private var lastReplyAt: Date?
    @ObservationIgnored private var pendingJog: (slot: Int, delta: Int)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isDisconnecting = false
    @ObservationIgnored private var heartbeatPending = false
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsPendingCommand: UInt8?
    @ObservationIgnored private var diagnosticsReplies: [UInt8: [UInt8]] = [:]

    private struct PreparedJog {
        let id = UUID()
        let packet: Data
        let deadline: ContinuousClock.Instant
        let slot: Int
        let before: Int
        let target: Int
    }

    private struct JogRefresh {
        let id = UUID()
        let packet: Data
        let deadline: ContinuousClock.Instant
        let slot: Int
        let before: Int
        let target: Int
        var frames = 0
        var awaitingWrite = false
    }

    public convenience init(demo: Bool = false) {
        self.init(transport: demo ? DemoRobotTransport() : CoreBluetoothTransport())
        if demo {
            bluetoothStatus = "Practice mode · no Bluetooth"
            statusMessage = "Practice mode uses a simulated robot. No hardware is controlled."
        }
    }

    init(transport: RobotTransport, now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.now = now
        transport.onEvent = { [weak self] event in self?.receive(event) }
    }

    public func startScan() {
        guard !isDisconnecting, [.idle, .failed].contains(phase) else { return }
        resetSession()
        devices = []; phase = .scanning; errorMessage = nil
        statusMessage = "Looking for nearby Meccanoid robots…"
        transport.startScan()
        guard phase == .scanning else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.phase == .scanning else { return }
            self.stopScan()
        }
    }

    public func stopScan() {
        transport.stopScan()
        if phase == .scanning {
            deadlineTask?.cancel(); phase = .idle
            statusMessage = devices.isEmpty ? "No robot found. Check its power and move closer, then scan again." : "Choose your robot to connect."
        }
    }

    public func connect(to id: UUID) {
        guard !isDisconnecting, [.scanning, .idle].contains(phase), let device = devices.first(where: { $0.id == id }) else { return }
        deadlineTask?.cancel(); transport.stopScan()
        resetSession(); errorMessage = nil; phase = .connecting
        connectedName = device.name
        statusMessage = "Connecting to \(device.name)…"
        log("Connecting to selected robot")
        connectionDeadline()
        transport.connect(to: id)
    }

    private func connectionDeadline() {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.connectionTimedOut()
        }
    }

    func connectionTimedOut() {
        switch phase {
        case .connecting:
            fail("Connection timed out before the robot was ready. Check its power, move closer, then scan again.")
        case .handshaking:
            fail("Robot confirmation timed out. Press its yellow button if it asks to connect, then scan again.")
        default: break
        }
    }

    public func disconnect() {
        guard !isDisconnecting else { return }
        if !isConnected {
            transport.disconnect(); resetSession(); phase = .idle; connectedName = nil
            statusMessage = "Disconnected"; return
        }
        stop()
        isDisconnecting = true
        statusMessage = "Disconnecting…"
        disconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.transport.disconnect()
            self.resetSession(); self.phase = .idle; self.connectedName = nil
            self.isDisconnecting = false; self.statusMessage = "Disconnected"
        }
    }

    public func setEyes(red: Int, green: Int, blue: Int, name: String) {
        guard isConnected, !isDisconnecting else { return }
        do {
            let command = try MeccanoidPacket.eyes(red: red, green: green, blue: blue)
            send(command) { [weak self] in
                self?.lastEyeColor = name
                self?.statusMessage = "\(name) command sent. Check the robot's eyes."
                self?.log("Eye colour sent: \(name)")
            }
        } catch { report(error.localizedDescription) }
    }

    public func confirmEyes() {
        guard isConnected, !isDisconnecting, lastEyeColor != nil else { return }
        eyesConfirmed = true
        log("Operator confirmed a physical eye-colour change")
        statusMessage = "Eyes confirmed. Movement controls can now be enabled."
    }

    public func setMotionEnabled(_ enabled: Bool) {
        if !enabled { stop(); return }
        guard !diagnosticsBusy else {
            report("Wait for the robot layout reading before enabling movement."); return
        }
        guard isConnected, !isDisconnecting, eyesConfirmed else {
            report("First send an eye colour and confirm you saw it on your robot."); return
        }
        motionEnabled = true
        statusMessage = "Movement enabled. Use one short movement at a time."
        log("Motion enabled by operator")
        refreshPose()
    }

    public func refreshPose() {
        guard isConnected, !isDisconnecting, !motionBusy, !poseRequestPending, pendingJog == nil else { return }
        requestPose()
    }

    /// These four requests only read configuration, mapping and reported modes.
    /// Keep one request outstanding; the wire protocol has no request identifiers.
    public func inspectRobot() {
        guard isConnected, !isDisconnecting, !diagnosticsBusy, !motionEnabled, !motionBusy, !modeRequestPending else { return }
        diagnostics = nil; diagnosticsReplies = [:]; diagnosticsBusy = true
        diagnosticsMessage = "Reading the robot layout…"
        diagnosticsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.diagnosticsTimedOut()
        }
        requestDiagnostics(command: 0x02)
    }

    func diagnosticsTimedOut() {
        guard diagnosticsBusy else { return }
        // Do not retry on the same connection: a delayed reply could otherwise
        // be mistaken for the new reading.
        fail("The robot layout reading timed out. Reconnect before trying again.")
    }

    private func requestDiagnostics(command: UInt8) {
        diagnosticsPendingCommand = command
        switch command {
        case 0x02: send(MeccanoidPacket.readModules(.channels1to4), quiet: true)
        case 0x03: send(MeccanoidPacket.readModules(.channels5to8), quiet: true)
        case 0x20: send(MeccanoidPacket.readServoMapping(), quiet: true)
        case 0x0A: send(MeccanoidPacket.readServoModes(), quiet: true)
        default: preconditionFailure("Unexpected diagnostic request")
        }
    }

    private func receiveDiagnostics(command: UInt8, values: [UInt8]) {
        guard diagnosticsBusy, !isDisconnecting, diagnosticsPendingCommand == command else { return }
        diagnosticsReplies[command] = values
        switch command {
        case 0x02: requestDiagnostics(command: 0x03)
        case 0x03: requestDiagnostics(command: 0x20)
        case 0x20: requestDiagnostics(command: 0x0A)
        case 0x0A:
            guard let first = diagnosticsReplies[0x02], let second = diagnosticsReplies[0x03],
                  let mapping = diagnosticsReplies[0x20],
                  let snapshot = RobotDiagnostics(firstBank: first, secondBank: second, mapping: mapping, modes: values) else {
                fail("The robot returned an incomplete layout. Reconnect before trying again."); return
            }
            diagnostics = snapshot
            diagnosticsBusy = false; diagnosticsPendingCommand = nil
            diagnosticsTask?.cancel(); diagnosticsTask = nil; diagnosticsReplies = [:]
            diagnosticsMessage = "\(snapshot.servoCount) servos reported. This reading does not identify which body part each one moves."
            log("Read robot layout: \(snapshot.servoCount) servos, \(snapshot.unmappedServoAddresses.count) outside the returned mapping")
        default: break
        }
    }

    private func requestPose() {
        guard !poseRequestPending else { return }
        poseRequestPending = true
        poseReadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.poseRequestPending else { return }
            self.stop()
            self.fail("No joint-position reply arrived. Reconnect before trying a nudge.")
        }
        send(MeccanoidPacket.readPose(), quiet: true)
    }

    public func jog(slot: Int, delta: Int) {
        guard canBeginMotion() else { return }
        guard !poseRequestPending, !modeRequestPending else {
            report("Wait for the current joint reading before nudging."); return
        }
        guard (0..<8).contains(slot), (-8...8).contains(delta), delta != 0 else {
            report("Joint nudges must be between −8 and +8 raw units."); return
        }
        guard diagnostics != nil else {
            report("Disable movement and read the robot layout before nudging a joint."); return
        }
        guard availableJointSlots.contains(where: { $0.slotIndex == slot && $0.isConfiguredServo }) else {
            report("This slot is not a configured servo in the current robot layout."); return
        }
        motionBusy = true; pendingJog = (slot, delta); positions = nil; jogSampleRequested = true
        // The original client reads the complete pose before requesting control
        // mode. Never insert another pose read between mode confirmation and 08.
        requestPose()
    }

    private func completeJog(with positions: [UInt8]) {
        guard let jog = pendingJog, jogSampleRequested, motionEnabled, !isDisconnecting else { return }
        pendingJog = nil; jogSampleRequested = false; actionTask?.cancel()
        let before = Int(positions[jog.slot]), target = before + jog.delta
        // These are protocol limits, not a claim about mechanical travel.
        guard (24...232).contains(before), (24...232).contains(target) else {
            motionBusy = false; report("This slot is absent or outside the supported nudge range."); return
        }
        var pose = positions; pose[jog.slot] = UInt8(target)
        do {
            let prepared = PreparedJog(
                packet: try MeccanoidPacket.pose(pose),
                deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                slot: jog.slot, before: before, target: target
            )
            preparedJog = prepared
            modeReadTask = Task { [weak self] in
                try? await ContinuousClock().sleep(until: prepared.deadline)
                guard !Task.isCancelled, let self,
                      self.modeRequestPending || self.preparedJog?.id == prepared.id else { return }
                self.stop()
                self.fail("No timely joint-mode confirmation arrived. Reconnect before trying a nudge.")
            }
            send(try MeccanoidPacket.servoMode(2), notAfter: prepared.deadline) { [weak self] in
                guard let self, self.preparedJog?.id == prepared.id, self.motionEnabled else { return }
                guard ContinuousClock.now < prepared.deadline else {
                    self.stop(); self.fail("The joint baseline expired before mode confirmation. Reconnect before trying again.")
                    return
                }
                self.modeRequestPending = true
                self.statusMessage = "Checking the selected joint's reported mode…"
                self.send(MeccanoidPacket.readServoModes(), quiet: true, notAfter: prepared.deadline)
            }
        } catch { stop(); report(error.localizedDescription) }
    }

    private func receiveJogModes(_ values: [UInt8]) {
        guard modeRequestPending else { return }
        // Drain this obligation even after Stop. Without request identifiers, a
        // new nudge must not consume an older mode response as its confirmation.
        modeRequestPending = false
        modeReadTask?.cancel(); modeReadTask = nil
        guard let prepared = preparedJog, motionEnabled, !isDisconnecting else { return }
        preparedJog = nil
        guard ContinuousClock.now < prepared.deadline else {
            stop(); report("The joint baseline expired before mode confirmation. Try a new nudge."); return
        }
        let mode = values[prepared.slot]
        guard mode == 2 else {
            stop()
            report("Joint \(prepared.slot + 1) reported mode \(mode); expected 2. No position command was sent. Movement is disabled.")
            return
        }
        log("Joint \(prepared.slot + 1) reported mode 2 before its position command")
        // Repetition never adds another delta or extends the frozen baseline's
        // lifetime, including a first frame queued behind transport backpressure.
        let refresh = JogRefresh(
            packet: prepared.packet,
            deadline: min(prepared.deadline, ContinuousClock.now.advanced(by: .seconds(1))),
            slot: prepared.slot, before: prepared.before, target: prepared.target
        )
        jogRefresh = refresh
        jogDeadlineTask = Task { [weak self] in
            try? await ContinuousClock().sleep(until: refresh.deadline)
            guard !Task.isCancelled, let self else { return }
            self.finishJogRefresh(id: refresh.id)
        }
        sendJogFrame(id: refresh.id)
    }

    private func sendJogFrame(id: UUID) {
        guard var refresh = jogRefresh, refresh.id == id,
              isConnected, motionEnabled, !isDisconnecting, !refresh.awaitingWrite else { return }
        guard ContinuousClock.now < refresh.deadline, refresh.frames < 10 else {
            finishJogRefresh(id: id); return
        }
        refresh.frames += 1
        refresh.awaitingWrite = true
        jogRefresh = refresh
        send(refresh.packet, quiet: true, notAfter: refresh.deadline) { [weak self] in
            guard let self, var current = self.jogRefresh, current.id == id else { return }
            current.awaitingWrite = false
            self.jogRefresh = current
            if current.frames == 1 {
                self.log("Joint \(current.slot + 1) target \(current.before) → \(current.target) accepted for bounded refresh")
                self.statusMessage = "Refreshing the same small joint target. Observe its direction and clearance."
            }
            guard ContinuousClock.now < current.deadline, current.frames < 10 else {
                self.finishJogRefresh(id: id); return
            }
            // Backpressure: one accepted frame, then a delay. Never catch up by
            // queuing a burst when a previous write was slow.
            self.actionTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.sendJogFrame(id: id)
            }
        }
    }

    private func finishJogRefresh(id: UUID) {
        guard let refresh = jogRefresh, refresh.id == id else { return }
        if refresh.awaitingWrite {
            // resetSession invalidates callbacks before cancelling unsent writes.
            // A command already handed to CoreBluetooth cannot be recalled.
            fail("Joint command did not complete within its refresh window. Reconnect before trying again.")
            return
        }
        jogRefresh = nil
        jogDeadlineTask?.cancel(); jogDeadlineTask = nil
        actionTask?.cancel()
        log("Bounded joint refresh finished after \(refresh.frames) frames")
        statusMessage = "Joint refresh finished. Waiting for position feedback…"
        let epoch = generation
        actionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.generation == epoch,
                  self.isConnected, self.motionEnabled, !self.isDisconnecting else { return }
            self.jogReadback = (refresh.slot, refresh.before, refresh.target)
            self.requestPose()
        }
    }

    public func drive(left: Int, right: Int) {
        guard canBeginMotion() else { return }
        guard (-40...40).contains(left), (-40...40).contains(right) else {
            report("Initial wheel pulses are limited to ±40 raw PWM units."); return
        }
        do {
            let command = try MeccanoidPacket.wheels(left: left, right: right)
            motionBusy = true
            send(command) { [weak self] in
                guard let self else { return }
                self.log("250 ms wheel pulse sent")
                self.statusMessage = "Short wheel pulse sent"
                self.actionTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self else { return }
                    self.send(MeccanoidPacket.zeroWheels()) { [weak self] in self?.motionBusy = false }
                }
            }
        } catch { motionBusy = false; report(error.localizedDescription) }
    }

    private func canBeginMotion() -> Bool {
        guard isConnected, !isDisconnecting, motionEnabled, eyesConfirmed else {
            report("Enable movement after confirming the eyes."); return false
        }
        guard !motionBusy, !diagnosticsBusy else { return false }
        errorMessage = nil; return true
    }

    public func stop() {
        generation += 1; actionTask?.cancel(); actionTask = nil
        jogDeadlineTask?.cancel(); jogDeadlineTask = nil; jogRefresh = nil
        jogReadback = nil
        heartbeatPending = false
        pendingJog = nil; motionBusy = false; motionEnabled = false
        jogSampleRequested = false; preparedJog = nil
        // Keep an already requested mode read and its deadline until it drains.
        if !modeRequestPending { modeReadTask?.cancel(); modeReadTask = nil }
        transport.cancelPendingWrites()
        guard isConnected else { return }
        send(MeccanoidPacket.zeroWheels())
        send(MeccanoidPacket.stopPreset())
        statusMessage = "Stop commands sent. Movement is disabled."
        log("Stop requested; pending motion cancelled")
    }

    public func appBecameInactive() {
        if motionEnabled || motionBusy { stop() }
        if phase == .scanning { stopScan() }
    }

    private func send(_ data: Data, quiet: Bool = false, notAfter: ContinuousClock.Instant? = nil,
                      onSent: @escaping () -> Void = {}) {
        guard isConnected || phase == .handshaking else { return }
        let epoch = generation
        transport.send(data, notAfter: notAfter) { [weak self] result in
            guard let self, epoch == self.generation else { return }
            switch result {
            case .success:
                if !quiet { self.log(String(format: "Bluetooth accepted command %02X", data.first ?? 0)) }
                onSent()
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }

    private func receive(_ event: TransportEvent) {
        switch event {
        case .bluetooth(let text): bluetoothStatus = text
        case .discovered(let device):
            guard phase == .scanning else { return }
            devices.removeAll { $0.id == device.id }; devices.append(device)
            devices.sort { $0.rssi > $1.rssi }
        case .connected:
            guard phase == .connecting else { return }
            statusMessage = "Discovering robot controls…"
            log("Bluetooth connected; discovering robot controls")
        case .subscribed:
            guard phase == .connecting else { return }
            phase = .handshaking; connectionDeadline()
            statusMessage = "Press the robot's yellow button if it asks to connect."
            log("Notifications enabled; requesting handshake")
            send(MeccanoidPacket.pin())
        case .received(let bytes):
            guard [.handshaking, .ready].contains(phase) else { return }
            guard let reply = MeccanoidPacket.decode(bytes) else { log("Ignored malformed robot notification"); return }
            if case .pin(let accepted) = reply, phase == .handshaking {
                guard accepted else { fail("Robot declined the connection. Try again and press its yellow button."); return }
                phase = .ready; deadlineTask?.cancel(); lastReplyAt = now()
                statusMessage = "Connected. Choose an eye colour to test."
                log("Robot accepted the handshake")
                send(MeccanoidPacket.zeroWheels())
                send(MeccanoidPacket.status(), quiet: true)
                startHeartbeat()
            } else if isConnected {
                lastReplyAt = now()
                switch reply {
                case .pose(let values):
                    guard poseRequestPending else { return }
                    poseRequestPending = false; poseReadTask?.cancel(); poseReadTask = nil
                    positions = values
                    if let readback = jogReadback {
                        jogReadback = nil; motionBusy = false
                        let measured = Int(values[readback.slot])
                        if measured == readback.before {
                            statusMessage = "Joint feedback stayed at \(measured). No movement is confirmed."
                            log("Joint \(readback.slot + 1) feedback unchanged at \(measured) after target \(readback.target)")
                        } else {
                            statusMessage = "Joint feedback received. Check whether the intended part moved."
                            log("Joint \(readback.slot + 1) feedback \(readback.before) → \(measured) after target \(readback.target)")
                        }
                    } else if pendingJog != nil { completeJog(with: values) }
                case .status(let value): robotStatus = value
                case .modules(let bank, let types): receiveDiagnostics(command: bank.rawValue, values: types)
                case .servoMapping(let values): receiveDiagnostics(command: 0x20, values: values)
                case .servoModes(let values):
                    if modeRequestPending { receiveJogModes(values) }
                    else { receiveDiagnostics(command: 0x0A, values: values) }
                default: break
                }
            }
        case .disconnected(let message):
            resetSession(); connectedName = nil; isDisconnecting = false
            if phase != .failed { phase = .idle; statusMessage = message ?? "Disconnected" }
            log("Bluetooth disconnected; motion state cleared")
        case .failed(let message): fail(message)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isConnected, !self.isDisconnecting else { return }
                self.checkHeartbeat()
            }
        }
    }

    func checkHeartbeat() {
        guard isConnected else { return }
        if let lastReplyAt, now().timeIntervalSince(lastReplyAt) > 5 {
            stop()
            fail("The robot stopped replying. Check its power and reconnect.")
            return
        }
        guard !heartbeatPending else { return }
        heartbeatPending = true
        send(MeccanoidPacket.status(), quiet: true) { [weak self] in self?.heartbeatPending = false }
    }

    private func fail(_ message: String) {
        // Set state before cancelling writes: cancellation callbacks must not
        // recursively start another failure or make a stale command look sent.
        resetSession(); phase = .failed; errorMessage = message; statusMessage = message
        devices = []
        isDisconnecting = false
        transport.disconnect(); log(message)
    }

    private func resetSession() {
        generation += 1
        deadlineTask?.cancel(); heartbeatTask?.cancel(); actionTask?.cancel(); disconnectTask?.cancel(); poseReadTask?.cancel(); jogDeadlineTask?.cancel()
        deadlineTask = nil; heartbeatTask = nil; actionTask = nil; disconnectTask = nil
        pendingJog = nil; motionBusy = false; motionEnabled = false; eyesConfirmed = false
        poseReadTask = nil; poseRequestPending = false; jogSampleRequested = false
        modeReadTask?.cancel(); modeReadTask = nil
        modeRequestPending = false; preparedJog = nil
        jogDeadlineTask = nil; jogRefresh = nil; jogReadback = nil
        positions = nil; robotStatus = nil; lastEyeColor = nil; lastReplyAt = nil; heartbeatPending = false
        diagnosticsTask?.cancel(); diagnosticsTask = nil
        diagnosticsPendingCommand = nil; diagnosticsReplies = [:]
        diagnostics = nil; diagnosticsBusy = false
        diagnosticsMessage = "Read the detected modules and joint slots without moving the robot."
        transport.cancelPendingWrites()
    }

    private func report(_ message: String) { errorMessage = message; log(message) }
    private func log(_ message: String) {
        logs.append(message)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }
}
