import Foundation
@preconcurrency import CoreBluetooth

/// No central manager (and no permission request) exists until the user scans.
@MainActor
final class CoreBluetoothTransport: NSObject, RobotTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onEvent: ((TransportEvent) -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var robot: CBPeripheral?
    private var writer: CBCharacteristic?
    private var reader: CBCharacteristic?
    private var wantsScan = false
    private var subscribed = false
    private var pending: [(Data, (Result<Void, Error>) -> Void)] = []
    private var inFlight: ((Result<Void, Error>) -> Void)?
    private var writeDeadline: Task<Void, Never>?
    private var isDraining = false
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private let serviceID = CBUUID(string: "FFF0")
    private let writeID = CBUUID(string: "FFF2")
    private let notifyID = CBUUID(string: "FFF1")

    func startScan() {
        wantsScan = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { beginScan() }
        else { reportState() }
    }

    private func beginScan() {
        peripherals.removeAll()
        // Some legacy firmware omits FFF0 from advertisements. Filter the name
        // here, then require the exact service and characteristics after connect.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() { wantsScan = false; central?.stopScan() }

    func connect(to id: UUID) {
        guard central?.state == .poweredOn, let peripheral = peripherals[id], robot == nil else {
            onEvent?(.failed("Robot is no longer available. Scan again.")); return
        }
        stopScan()
        robot = peripheral
        peripheral.delegate = self
        central?.connect(peripheral, options: nil)
    }

    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard robot?.state == .connected, writer != nil else {
            completion(.failure(LinkError(message: "Robot is disconnected."))); return
        }
        guard data.count == 20 else {
            completion(.failure(LinkError(message: "Invalid command length."))); return
        }
        pending.append((data, completion))
        armWriteDeadline()
        drain()
    }

    private func drain() {
        guard !isDraining, let robot, robot.state == .connected, let writer, inFlight == nil else { return }
        isDraining = true
        defer { isDraining = false }
        while !pending.isEmpty {
            if writeType == .withoutResponse && !robot.canSendWriteWithoutResponse { return }
            let (data, completion) = pending.removeFirst()
            if writeType == .withResponse { inFlight = completion }
            robot.writeValue(data, for: writer, type: writeType)
            if writeType == .withResponse { return }
            // CoreBluetooth accepted the write. This is NOT a robot acknowledgement.
            completion(.success(()))
        }
        writeDeadline?.cancel(); writeDeadline = nil
    }

    private func armWriteDeadline() {
        guard writeDeadline == nil else { return }
        writeDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.writeDeadline = nil
            if self.inFlight != nil || !self.pending.isEmpty {
                self.fail("Bluetooth writes stalled. Reconnect before sending more commands.")
            }
        }
    }

    func cancelPendingWrites() {
        let cancelled = pending; pending.removeAll()
        if inFlight == nil { writeDeadline?.cancel(); writeDeadline = nil }
        for item in cancelled { item.1(.failure(LinkError(message: "Command cancelled."))) }
        // A write already handed to CoreBluetooth cannot be recalled. Preserve its
        // response slot so a late acknowledgement cannot complete a newer write.
    }

    func disconnect() {
        stopScan(); cancelPendingWrites()
        guard let robot else { return }
        central?.cancelPeripheralConnection(robot)
    }

    private func clearConnection() {
        writeDeadline?.cancel(); writeDeadline = nil
        cancelPendingWrites()
        let completion = inFlight; inFlight = nil
        completion?(.failure(LinkError(message: "Robot disconnected.")))
        robot?.delegate = nil; robot = nil; writer = nil; reader = nil; subscribed = false
    }

    private func fail(_ message: String) {
        let oldRobot = robot
        clearConnection()
        if let oldRobot { central?.cancelPeripheralConnection(oldRobot) }
        onEvent?(.failed(message))
    }

    private func reportState() {
        guard let central else { return }
        let text: String
        switch central.state {
        case .poweredOn: text = "Bluetooth is on"
        case .poweredOff: text = "Bluetooth is off. Turn it on in Settings."
        case .unauthorized: text = "Allow Bluetooth access for Meccanoid Link in Settings."
        case .unsupported: text = "Bluetooth is unavailable on this device."
        case .resetting: text = "Bluetooth is restarting."
        case .unknown: text = "Checking Bluetooth…"
        @unknown default: text = "Bluetooth state is unavailable."
        }
        onEvent?(.bluetooth(text))
        if [.poweredOff, .unauthorized, .unsupported].contains(central.state) {
            wantsScan = false
            if robot != nil { clearConnection() }
            onEvent?(.failed(text))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        reportState()
        if central.state == .poweredOn && wantsScan { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard wantsScan else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.uppercased().hasPrefix("MECCANOID") else { return }
        peripherals[peripheral.identifier] = peripheral
        onEvent?(.discovered(DiscoveredRobot(id: peripheral.identifier, name: name, rssi: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === robot else { central.cancelPeripheralConnection(peripheral); return }
        onEvent?(.connected)
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === robot else { return }
        fail(error?.localizedDescription ?? "Could not connect to the robot.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === robot else { return }
        clearConnection()
        onEvent?(.disconnected(error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === robot else { return }
        if let error { fail(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            fail("This robot does not expose the supported FFF0 service."); return
        }
        peripheral.discoverCharacteristics([writeID, notifyID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === robot else { return }
        if let error { fail(error.localizedDescription); return }
        writer = service.characteristics?.first(where: { $0.uuid == writeID })
        reader = service.characteristics?.first(where: { $0.uuid == notifyID })
        guard let writer, let reader, reader.properties.contains(.notify) else {
            fail("Required Bluetooth control channels were not found."); return
        }
        if writer.properties.contains(.writeWithoutResponse) { writeType = .withoutResponse }
        else if writer.properties.contains(.write) { writeType = .withResponse }
        else { fail("Robot control channel is not writable."); return }
        peripheral.setNotifyValue(true, for: reader)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === robot, characteristic.uuid == notifyID else { return }
        if let error { fail(error.localizedDescription); return }
        guard characteristic.isNotifying else { fail("Robot notifications could not be enabled."); return }
        if !subscribed { subscribed = true; onEvent?(.subscribed) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === robot, characteristic.uuid == notifyID else { return }
        if let error { fail(error.localizedDescription); return }
        if let data = characteristic.value { onEvent?(.received(data)) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === robot, characteristic.uuid == writeID else { return }
        let completion = inFlight; inFlight = nil
        writeDeadline?.cancel(); writeDeadline = nil
        if let error { completion?(.failure(error)); fail(error.localizedDescription) }
        else {
            completion?(.success(()))
            if !pending.isEmpty { armWriteDeadline() }
            drain()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === robot else { return }; drain()
    }
}
