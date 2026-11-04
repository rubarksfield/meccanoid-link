import SwiftUI
import MeccanoidBluetooth

@MainActor
struct ContentView: View {
    let controller: RobotController
    let isDemo: Bool

    @State private var selectedJoint = 0
    @State private var nudgeSize = 3
    @State private var showingDetails = false

    private let eyeColours: [EyeColour] = [
        .init(name: "Blue", red: 0, green: 0, blue: 7, colour: .blue),
        .init(name: "Green", red: 0, green: 7, blue: 0, colour: .green),
        .init(name: "Red", red: 7, green: 0, blue: 0, colour: .red),
        .init(name: "Purple", red: 7, green: 0, blue: 7, colour: .purple),
        .init(name: "Amber", red: 7, green: 4, blue: 0, colour: .orange),
        .init(name: "White", red: 7, green: 7, blue: 7, colour: .white)
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if isDemo { practiceBanner }
                    if let error = controller.errorMessage, !error.isEmpty {
                        errorBanner(error)
                    }
                    if geometry.size.width >= 800 {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 20) {
                                connectionPanel
                                eyesPanel
                            }
                            .frame(maxWidth: 400)
                            VStack(spacing: 20) {
                                movementPanel
                                detailsPanel
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 20) {
                            connectionPanel
                            eyesPanel
                            movementPanel
                            detailsPanel
                        }
                    }
                    Text("Community software for your Meccanoid. Your robot stays in your control.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(geometry.size.width < 500 ? 20 : 32)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(Color.primary.opacity(0.035))
        }
        .tint(LinkTheme.blue)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if controller.isConnected {
                persistentStopBar
            }
        }
        .onChange(of: controller.isConnected) { _, connected in
            if !connected { selectedJoint = 0; nudgeSize = 3 }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            RobotEyes(colour: LinkTheme.blue, isLit: true)
                .frame(width: 60, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Meccanoid Link")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LinkTheme.blue)
                Text("A fresh connection to your robot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var practiceBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Practice mode").font(.subheadline.weight(.semibold))
                Text("Try the controls with a simulated robot. Bluetooth is not used.")
                    .font(.footnote)
            }
        } icon: {
            Image(systemName: "sparkles.rectangle.stack")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(LinkTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("practiceBanner")
    }

    private var connectionPanel: some View {
        LinkPanel(title: "Connect", symbol: "antenna.radiowaves.left.and.right", step: "01") {
            HStack(spacing: 7) {
                Circle().fill(connectionTint).frame(width: 7, height: 7)
                Text(connectionTitle).font(.subheadline.weight(.semibold))
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .combine)

            Text(controller.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("connectionStatus")

            if controller.isConnected {
                if let name = controller.connectedName {
                    Label(name, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LinkTheme.blue)
                }
                Button("Disconnect", action: controller.disconnect)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("disconnectButton")
            } else {
                if controller.phase == .scanning {
                    Button("Stop searching", action: controller.stopScan)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("stopScanButton")
                } else {
                    Button(action: controller.startScan) {
                        Label(isDemo ? "Find practice robot" : "Find my robot", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy)
                    .accessibilityIdentifier("scanButton")
                }

                if !controller.devices.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(controller.devices) { robot in
                            Button {
                                controller.connect(to: robot.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text(robot.name)
                                        .font(.subheadline.weight(.semibold))
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 6)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                                .padding(13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LinkTheme.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(controller.phase == .connecting || controller.phase == .handshaking)
                            .accessibilityLabel("Connect to \(robot.name)")
                            .accessibilityIdentifier("robot-\(robot.id.uuidString)")
                        }
                    }
                }

                if !isDemo {
                    Text("Turn your robot on with its battery charged and USB unplugged. Press its yellow button if it asks to connect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var eyesPanel: some View {
        LinkPanel(title: "Start with the eyes", symbol: "eyes", step: "02") {
            HStack(spacing: 18) {
                RobotEyes(colour: selectedEyeColour, isLit: controller.lastEyeColor != nil)
                    .frame(width: 104, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a colour")
                        .font(.subheadline.weight(.semibold))
                    Text("Watch your robot’s eyes to check the connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(eyeColours) { colour in
                    eyeButton(colour)
                }
            }
            .disabled(!controller.isConnected)

            if let colour = controller.lastEyeColor {
                Label(isDemo ? "Practice colour: \(colour)" : "Colour sent: \(colour)", systemImage: "paperplane")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("eyeCommandStatus")
                if controller.eyesConfirmed {
                    Label(isDemo ? "Practice check complete" : "Eye change confirmed by you", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("eyesConfirmed")
                } else {
                    Button(isDemo ? "Confirm practice colour" : "I saw the eyes change", action: controller.confirmEyes)
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.isConnected)
                        .accessibilityIdentifier("confirmEyesButton")
                }
            } else {
                Text(controller.isConnected ? "Pick a colour above to send the first command." : "Connect to a robot to try its lights.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var movementPanel: some View {
        LinkPanel(title: "Make a small move", symbol: "move.3d", step: "03") {
            Toggle("Enable movement", isOn: Binding(
                get: { controller.motionEnabled },
                set: { controller.setMotionEnabled($0) }
            ))
            .font(.subheadline.weight(.semibold))
            .disabled(!controller.isConnected || !controller.eyesConfirmed || controller.diagnosticsBusy)
            .accessibilityIdentifier("motionToggle")

            Text(movementGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Wheels").font(.subheadline.weight(.semibold))
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        directionButton("Forward", symbol: "arrow.up", left: 40, right: 40)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    GridRow {
                        directionButton("Left", symbol: "arrow.turn.up.left", left: -40, right: 40)
                        if controller.motionBusy {
                            ProgressView()
                                .accessibilityLabel("Movement command in progress")
                        } else {
                            Image(systemName: "circle.dotted")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        directionButton("Right", symbol: "arrow.turn.up.right", left: 40, right: -40)
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        directionButton("Back", symbol: "arrow.down", left: -40, right: -40)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(!controller.motionEnabled || controller.motionBusy)
                Text(controller.motionBusy ? "Movement command in progress…" : "Each tap sends a short, low-speed pulse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            jointControls
        }
    }

    private var persistentStopBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isDemo ? "Practice control" : "Robot control")
                    .font(.subheadline.weight(.semibold))
                Text(controller.motionBusy ? "Command in progress" : (controller.motionEnabled ? "Movement enabled" : "Movement disabled"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: controller.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 88, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Stop movement")
            .accessibilityHint("Sends a stop command and disables movement controls.")
            .accessibilityIdentifier("stopButton")
        }
        .frame(maxWidth: 1036)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("persistentStopBar")
    }

    private var jointControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("One joint at a time").font(.subheadline.weight(.semibold))
                Spacer()
                if !controller.availableJointSlots.isEmpty {
                    Picker("Joint", selection: Binding(
                        get: { currentJoint ?? -1 },
                        set: { selectedJoint = $0 }
                    )) {
                        ForEach(controller.availableJointSlots, id: \.slotIndex) { slot in
                            Text("Joint slot \(slot.slotIndex + 1)").tag(slot.slotIndex)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Choose detected joint")
                    .accessibilityIdentifier("jointPicker")
                    .disabled(controller.motionBusy)
                }
            }

            Button(controller.motionEnabled ? "Stop and find connected joints" : "Find connected joints") {
                if controller.motionEnabled { controller.stop() }
                controller.inspectRobot()
            }
            .buttonStyle(.bordered)
            .disabled(!controller.isConnected || controller.motionBusy || controller.diagnosticsBusy)
            .accessibilityIdentifier("findJointsButton")

            if controller.diagnosticsBusy {
                Text("Reading connected joints…").font(.caption).foregroundStyle(.secondary)
            } else if let layout = controller.diagnostics {
                Text("\(controller.availableJointSlots.count) joint slots available from \(layout.servoCount) detected servos.")
                    .font(.caption).foregroundStyle(.secondary)
                if !layout.unmappedServoAddresses.isEmpty {
                    Text("Some servos are missing from the robot’s slot mapping. They cannot be selected here yet.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                Button(action: controller.refreshPose) {
                    Label("Read position", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!controller.isConnected || controller.motionBusy)
                .accessibilityIdentifier("readPoseButton")
                Spacer(minLength: 0)
                if controller.motionBusy {
                    Text("Updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let position = currentPosition {
                    Text("Position \(position)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Nudge size", selection: $nudgeSize) {
                Text("3 units").tag(3)
                Text("8 units").tag(8)
            }
            .pickerStyle(.segmented)
            .disabled(controller.motionBusy)
            .accessibilityIdentifier("nudgeSizePicker")

            HStack(spacing: 10) {
                jointButton("Nudge −", delta: -nudgeSize)
                jointButton("Nudge +", delta: nudgeSize)
            }
            .disabled(!controller.motionEnabled || currentJoint == nil || currentPosition == nil || controller.motionBusy)

            Text(controller.diagnostics == nil
                 ? "Find connected joints first. Only slots reporting a servo will be offered."
                 : "The app checks control mode before sending a tiny nudge. Slot numbers do not identify body parts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if nudgeSize == 8 {
                Text("Eight raw units is a larger test, not an angle in degrees. Keep the joint clear and Stop within reach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailsPanel: some View {
        DisclosureGroup(isExpanded: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bluetooth: \(controller.bluetoothStatus)")
                    .font(.footnote)
                robotLayoutDetails
                Divider()
                if controller.logs.isEmpty {
                    Text("Connection activity will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(controller.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Text("A command being sent does not confirm that the robot moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        } label: {
            Label("Connection details", systemImage: "waveform.path")
                .font(.subheadline.weight(.medium))
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07)))
        .accessibilityIdentifier("connectionDetails")
    }

    private var robotLayoutDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: controller.inspectRobot) {
                Label(controller.diagnosticsBusy ? "Reading robot layout…" : "Read robot layout", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(!controller.isConnected || controller.motionEnabled || controller.motionBusy || controller.diagnosticsBusy)
            .accessibilityIdentifier("readRobotLayoutButton")

            Text(controller.motionEnabled ? "Disable movement to read the robot layout." : controller.diagnosticsMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let snapshot = controller.diagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected modules").font(.caption.weight(.semibold))
                    ForEach(snapshot.modules.filter { $0.typeCode != 0 }, id: \.address.rawValue) { module in
                        Text("\(module.address.displayName): \(module.typeDescription)")
                            .font(.caption)
                    }
                    Text("Joint slots").font(.caption.weight(.semibold)).padding(.top, 4)
                    ForEach(Array(snapshot.mappedSlots.prefix(8)), id: \.slotIndex) { slot in
                        Text("Slot \(slot.slotIndex + 1): \(slot.summary) · mode \(slot.modeCode)")
                            .font(.caption.monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !snapshot.unmappedServoAddresses.isEmpty {
                        Text("Servos outside the returned mapping: \(snapshot.unmappedServoAddresses.map(\.displayName).joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Modes are raw reported codes. Reading this layout does not change wiring, mapping or servo mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("robotLayoutSnapshot")
            }
            if let status = controller.robotStatus {
                Text("Latest status packet: \(status.raw.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func eyeButton(_ colour: EyeColour) -> some View {
        Button {
            controller.setEyes(red: colour.red, green: colour.green, blue: colour.blue, name: colour.name)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(colour.colour)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                    .frame(width: 15, height: 15)
                Text(colour.name).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                controller.lastEyeColor == colour.name ? LinkTheme.blue : .clear,
                lineWidth: 1.5
            ))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set eyes to \(colour.name.lowercased())")
        .accessibilityIdentifier("eyes-\(colour.name.lowercased())")
    }

    private func directionButton(_ title: String, symbol: String, left: Int, right: Int) -> some View {
        Button {
            controller.drive(left: left, right: right)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3.weight(.medium))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 5)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Move \(title.lowercased()) briefly")
        .accessibilityIdentifier("drive-\(title.lowercased())")
    }

    private func jointButton(_ title: String, delta: Int) -> some View {
        Button {
            guard let slot = currentJoint else { return }
            controller.jog(slot: slot, delta: delta)
        } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(currentJoint.map { "Nudge joint \($0 + 1) \(delta < 0 ? "down" : "up") \(abs(delta)) units" } ?? "Find connected joints before nudging")
        .accessibilityIdentifier(delta < 0 ? "jogMinusButton" : "jogPlusButton")
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("errorBanner")
    }

    private var currentPosition: UInt8? {
        guard let slot = currentJoint, let positions = controller.positions, positions.indices.contains(slot) else { return nil }
        return positions[slot]
    }

    private var currentJoint: Int? {
        controller.availableJointSlots.first(where: { $0.slotIndex == selectedJoint })?.slotIndex
            ?? controller.availableJointSlots.first?.slotIndex
    }

    private var selectedEyeColour: Color {
        eyeColours.first(where: { $0.name == controller.lastEyeColor })?.colour ?? LinkTheme.blue
    }

    private var isBusy: Bool {
        switch controller.phase {
        case .scanning, .connecting, .handshaking: true
        default: false
        }
    }

    private var connectionTitle: String {
        switch controller.phase {
        case .idle: "Ready when you are"
        case .scanning: "Looking for robots"
        case .connecting: "Connecting"
        case .handshaking: "Waiting for your robot"
        case .ready: isDemo ? "Practice robot connected" : "Connected"
        case .failed: "Connection needs attention"
        }
    }

    private var connectionTint: Color {
        switch controller.phase {
        case .ready: .green
        case .failed: .orange
        case .scanning, .connecting, .handshaking: LinkTheme.blue
        case .idle: .secondary
        }
    }

    private var movementGuidance: String {
        if !controller.isConnected { return "Connect your robot and check its eyes before enabling movement." }
        if !controller.eyesConfirmed { return "Change an eye colour and confirm that you saw it first." }
        if controller.motionEnabled { return "Keep space around the robot and its power switch within reach." }
        return "The eyes check is complete. Enable movement when you’re ready for a small test."
    }
}

private enum LinkTheme {
    static let blue = Color("LinkBlue")
}

private struct EyeColour: Identifiable {
    let name: String
    let red: Int
    let green: Int
    let blue: Int
    let colour: Color
    var id: String { name }
}

private struct RobotEyes: View {
    let colour: Color
    let isLit: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: geometry.size.height * 0.28)
                    .fill(LinkTheme.blue.opacity(0.09))
                HStack(spacing: geometry.size.width * 0.10) {
                    ForEach(0..<2) { _ in
                        RoundedRectangle(cornerRadius: geometry.size.height * 0.12)
                            .fill(isLit ? colour : .secondary.opacity(0.30))
                            .overlay(alignment: .topLeading) {
                                Circle().fill(.white.opacity(0.65))
                                    .frame(width: geometry.size.width * 0.055)
                                    .padding(geometry.size.height * 0.08)
                            }
                            .frame(width: geometry.size.width * 0.22, height: geometry.size.height * 0.42)
                    }
                }
            }
        }
    }
}

private struct LinkPanel<Content: View>: View {
    let title: String
    let symbol: String
    let step: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(LinkTheme.blue)
                Text(title).font(.headline)
                Spacer(minLength: 0)
                Text(step)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07)))
    }
}
