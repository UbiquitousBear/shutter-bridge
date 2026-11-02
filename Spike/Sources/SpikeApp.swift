import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications

@main
struct SpikeApp: App {
    @UIApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate
    // The log and the proximity watcher are shared instances: the app delegate uses them on a Bluetooth
    // relaunch, when no scene (and so no SwiftUI view) exists.
    @State private var log: SpikeLog
    @State private var browser: DeviceBrowser
    @State private var continued: ContinuedTask
    @State private var lifecycle: LifecycleMonitor
    @State private var proximity = ProximityWatcher.shared
    @State private var photos = PhotosProbe()
    /// The Wired and Wi-Fi tabs' state, shared with the Guided tab's runner.
    @State private var usb: USBLab
    @State private var wireless: WirelessLab
    @State private var guided: GuidedRunner
    @State private var scanner: AdvertisementScanner
    /// Build 10: the Bluetooth Wi-Fi handover lab, shared by the Bluetooth tab and the Guided tab's runner.
    @State private var handover: SonyWiFiHandover

    init() {
        // Must be registered before the app finishes launching (day 5 test).
        ContinuedTask.registerLaunchHandler()
        let log = SpikeLog.shared
        let browser = DeviceBrowser()
        let continued = ContinuedTask()
        let lifecycle = LifecycleMonitor()
        let usb = USBLab(browser: browser, log: log, lifecycle: lifecycle)
        let wireless = WirelessLab(log: log, continued: continued, lifecycle: lifecycle)
        let scanner = AdvertisementScanner()
        scanner.log = log
        let handover = SonyWiFiHandover(log: log)
        // Weak references: the scanner's camera identifiers are its first route to the camera, and the Wi-Fi tab's
        // typed SSID and passphrase are what the camera's are compared with (yes/no only).
        handover.scanner = scanner
        handover.wireless = wireless
        _handover = State(initialValue: handover)
        _scanner = State(initialValue: scanner)
        _log = State(initialValue: log)
        _browser = State(initialValue: browser)
        _continued = State(initialValue: continued)
        _lifecycle = State(initialValue: lifecycle)
        _usb = State(initialValue: usb)
        _wireless = State(initialValue: wireless)
        _guided = State(initialValue: GuidedRunner(log: log, browser: browser, usb: usb, wireless: wireless,
                                                   scanner: scanner, continued: continued, lifecycle: lifecycle,
                                                   proximity: ProximityWatcher.shared, handover: handover))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(log)
                .environment(browser)
                .environment(continued)
                .environment(lifecycle)
                .environment(proximity)
                .environment(photos)
                .environment(usb)
                .environment(wireless)
                .environment(guided)
                .environment(scanner)
                .environment(handover)
                .task {
                    browser.log = log
                    continued.log = log
                    lifecycle.log = log
                    proximity.log = log
                    photos.log = log
                    log.note("Spike UI ready. Day plan: docs/spike-plan.md")
                }
        }
    }
}

/// Runs at every launch, including when iOS relaunches the app in the background for Bluetooth (day 6): logs
/// the device context once, sets the notification delegate before launch finishes (Apple requires it), and
/// recreates the proximity watcher's restorable CBCentralManager.
final class SpikeAppDelegate: NSObject, UIApplicationDelegate {
    /// UNUserNotificationCenter.delegate is weak; this keeps it alive.
    private let notificationDelegate = ProximityNotificationDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let log = SpikeLog.shared
        log.noteLaunch("app state \(ProximityWatcher.appStateDescription())")
        UNUserNotificationCenter.current().delegate = notificationDelegate
        ProximityWatcher.shared.launch(log: log, launchOptions: launchOptions)
        return true
    }
}
