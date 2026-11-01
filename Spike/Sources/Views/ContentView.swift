import SwiftUI

struct ContentView: View {
    enum SpikeTab: Hashable {
        case wired, wifi, bluetooth, background, log
    }

    @Environment(ProximityWatcher.self) private var proximity
    @Environment(SpikeLog.self) private var log
    @State private var selection: SpikeTab = .wired

    var body: some View {
        TabView(selection: $selection) {
            Tab("Wired", systemImage: "cable.connector", value: SpikeTab.wired) { WiredView() }
            Tab("Wi-Fi", systemImage: "wifi", value: SpikeTab.wifi) { WirelessView() }
            Tab("Bluetooth", systemImage: "dot.radiowaves.left.and.right", value: SpikeTab.bluetooth) { BluetoothView() }
            Tab("Background", systemImage: "moon.zzz", value: SpikeTab.background) { BackgroundView() }
            Tab("Log", systemImage: "list.bullet.rectangle", value: SpikeTab.log) { LogView() }
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
