import SwiftUI
import BackgroundTasks

@main
struct SpikeApp: App {
    @State private var log = SpikeLog()
    @State private var browser = DeviceBrowser()
    @State private var continued = ContinuedTask()
    @State private var lifecycle = LifecycleMonitor()

    init() {
        // Must be registered before the app finishes launching (day 5 test).
        ContinuedTask.registerLaunchHandler()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(log)
                .environment(browser)
                .environment(continued)
                .environment(lifecycle)
                .task {
                    browser.log = log
                    continued.log = log
                    lifecycle.log = log
                    log.note("Spike launched. Day plan: docs/spike-plan.md")
                }
        }
    }
}
