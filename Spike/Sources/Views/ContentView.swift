import SwiftUI

struct ContentView: View {
    enum SpikeTab: Hashable {
        case guided, wired, wifi, bluetooth, background, log
    }

    @Environment(ProximityWatcher.self) private var proximity
    @Environment(SpikeLog.self) private var log
    @Environment(GuidedRunner.self) private var runner
    @State private var selection: SpikeTab = .wired

    var body: some View {
        TabView(selection: $selection) {
            Tab("Guided", systemImage: "checklist", value: SpikeTab.guided) { GuidedView() }
            Tab("Wired", systemImage: "cable.connector", value: SpikeTab.wired) { WiredView() }
            Tab("Wi-Fi", systemImage: "wifi", value: SpikeTab.wifi) { WirelessView() }
            Tab("Bluetooth", systemImage: "dot.radiowaves.left.and.right", value: SpikeTab.bluetooth) { BluetoothView() }
            Tab("Background", systemImage: "moon.zzz", value: SpikeTab.background) { BackgroundView() }
            Tab("Log", systemImage: "list.bullet.rectangle", value: SpikeTab.log) { LogView() }
        }
        // A guided run's alerts show over whichever tab is open.
        .alert(runner.prompt?.title ?? "", isPresented: Binding(get: { runner.prompt != nil }, set: { _ in }),
               presenting: runner.prompt) { prompt in
            ForEach(prompt.buttons, id: \.self) { title in
                Button(title) { runner.answer(title, for: prompt.id) }
            }
            if prompt.allowsCancel {
                Button(GuidedRunner.cancelLabel, role: .cancel) { runner.answer(GuidedRunner.cancelLabel, for: prompt.id) }
            }
        } message: { prompt in
            Text(prompt.message)
        }
        // "Import now" on the proximity reminder lands here, possibly before this view existed (initial: true).
        .onChange(of: proximity.importRequestedAt, initial: true) { _, requested in
            guard requested != nil else { return }
            proximity.consumeImportRequest()
            selection = .wired
            log.note("proximity: Import now opened the Wired tab (production starts the import here)")
        }
    }
}
