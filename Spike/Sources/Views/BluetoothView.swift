import SwiftUI

struct BluetoothView: View {
    @Environment(SpikeLog.self) private var log
    @State private var scanner = AdvertisementScanner()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("State", value: scanner.state)
                    Button("Scan (Sony only)") { scanner.log = log; scanner.start(sonyOnly: true) }
                    Button("Scan (everything)") { scanner.log = log; scanner.start(sonyOnly: false) }
                    Button("Stop and summarise") { scanner.stop() }
                }
                Section("Seen (\(scanner.seen.count))") {
                    ForEach(scanner.seen.values.sorted { $0.rssi > $1.rssi }) { s in
                        VStack(alignment: .leading) {
                            Text("\(s.name)  \(s.rssi) dBm  ×\(s.count)").font(.headline)
                            Text("services: \(s.serviceUUIDs.isEmpty ? "none" : s.serviceUUIDs.joined(separator: ", "))").font(.caption)
                            Text("mfg: \(s.manufacturerHex)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Repeat with the camera on, asleep, and powered off (Bluetooth Function on, Remote Power ON/OFF on). The service UUID the camera advertises in all three states is the one the production proximity reminder filters on.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bluetooth")
        }
    }
}
