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
    public var isConnected: Bool { phase == .ready }

    @ObservationIgnored private let transport: RobotTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var poseReadTask: Task<Void, Never>?
    @ObservationIgnored private var poseRequestPending = false
    @ObservationIgnored private var jogSampleRequested = false
    @ObservationIgnored private var lastReplyAt: Date?
    @ObservationIgnored private var pendingJog: (slot: Int, delta: Int)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isDisconnecting = false
    @ObservationIgnored private var heartbeatPending = false

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
        guard isConnected, !isDisconnecting, eyesConfirmed else {
            report("First send an eye colour and confirm you saw it on your robot."); return
        }
        motionEnabled = true
        statusMessage = "Movement enabled. Use one short movement at a time."
        log("Motion enabled by operator")
        refreshPose()
    }

    public func refreshPose() {
        guard isConnected, !isDisconnecting, !poseRequestPending, pendingJog == nil else { return }
        requestPose()
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
        guard !poseRequestPending else {
            report("Wait for the current position reading before nudging."); return
        }
        guard (0..<8).contains(slot), (-3...3).contains(delta), delta != 0 else {
            report("Joint nudges must be between −3 and +3 raw units."); return
        }
        motionBusy = true; pendingJog = (slot, delta); positions = nil; jogSampleRequested = false
        do {
            // Sample again after entering control mode. Never send a guessed or
            // cached complete pose, and preserve every unselected returned slot.
            send(try MeccanoidPacket.servoMode(2)) { [weak self] in
                guard let self, self.pendingJog != nil, self.motionEnabled else { return }
                self.jogSampleRequested = true
                self.requestPose()
            }
        } catch { stop(); report(error.localizedDescription) }
    }

    private func completeJog(with positions: [UInt8]) {
        guard let jog = pendingJog, jogSampleRequested, motionEnabled, !isDisconnecting else { return }
        pendingJog = nil; jogSampleRequested = false; actionTask?.cancel()
        let before = Int(positions[jog.slot]), target = before + jog.delta
        // These are protocol limits, not a claim about any joint's mechanical
        // travel. Initial exploration is deliberately limited to three raw units.
        guard (24...232).contains(before), (24...232).contains(target) else {
            motionBusy = false; report("This slot is absent or outside the supported nudge range."); return
        }
        var pose = positions; pose[jog.slot] = UInt8(target)
        do {
            send(try MeccanoidPacket.pose(pose)) { [weak self] in
                guard let self else { return }
                self.log("Joint \(jog.slot + 1) nudge sent (\(jog.delta > 0 ? "+" : "")\(jog.delta) raw units)")
                self.statusMessage = "Small joint nudge sent. Observe its direction and clearance."
                self.actionTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.motionBusy = false; self.refreshPose()
                }
            }
        } catch { motionBusy = false; report(error.localizedDescription) }
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
        guard !motionBusy else { return false }
        errorMessage = nil; return true
    }

    public func stop() {
        generation += 1; actionTask?.cancel(); actionTask = nil
        heartbeatPending = false
        pendingJog = nil; motionBusy = false; motionEnabled = false
        jogSampleRequested = false
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

    private func send(_ data: Data, quiet: Bool = false, onSent: @escaping () -> Void = {}) {
        guard isConnected || phase == .handshaking else { return }
        let epoch = generation
        transport.send(data) { [weak self] result in
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
                    if pendingJog != nil { completeJog(with: values) }
                case .status(let value): robotStatus = value
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
        deadlineTask?.cancel(); heartbeatTask?.cancel(); actionTask?.cancel(); disconnectTask?.cancel(); poseReadTask?.cancel()
        deadlineTask = nil; heartbeatTask = nil; actionTask = nil; disconnectTask = nil
        pendingJog = nil; motionBusy = false; motionEnabled = false; eyesConfirmed = false
        poseReadTask = nil; poseRequestPending = false; jogSampleRequested = false
        positions = nil; robotStatus = nil; lastEyeColor = nil; lastReplyAt = nil; heartbeatPending = false
        transport.cancelPendingWrites()
    }

    private func report(_ message: String) { errorMessage = message; log(message) }
    private func log(_ message: String) {
        logs.append(message)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }
}
