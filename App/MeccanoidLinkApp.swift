import SwiftUI
import MeccanoidBluetooth

@main
@MainActor
struct MeccanoidLinkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: RobotController
    private let isDemo: Bool

    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        isDemo = demo
        _controller = State(initialValue: RobotController(demo: demo))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, isDemo: isDemo)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        controller.appBecameInactive()
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1020, height: 820)
        #endif
    }
}
