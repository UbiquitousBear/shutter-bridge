import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Wired", systemImage: "cable.connector") { WiredView() }
            Tab("Wi-Fi", systemImage: "wifi") { WirelessView() }
            Tab("Bluetooth", systemImage: "dot.radiowaves.left.and.right") { BluetoothView() }
            Tab("Background", systemImage: "moon.zzz") { BackgroundView() }
            Tab("Log", systemImage: "list.bullet.rectangle") { LogView() }
        }
    }
}
