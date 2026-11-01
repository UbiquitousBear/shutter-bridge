import Foundation

/// Day 10: renders the measurements table in docs/spike-plan.md ("Measurements and go/no-go criteria") from the
/// log, so the go/no-go table is pasted, not retyped. Each cell is the LATEST value recorded under its
/// measurement name ("—" when nothing was recorded), then comes an "All measurements" table and the device the
/// numbers came from.
///
/// The row → measurement-name mapping is the one static table below: edit it there if a name changes. The names
/// are a contract with the code that records them (Wired, Wi-Fi, Bluetooth and Background tabs).
///
/// Foundation-only (no SpikeLog, no UIKit) so it typechecks and self-checks on Linux; SpikeLog maps its
/// measurements onto `Sample` (see `SpikeLog.measurementsTableMarkdown`).
enum MeasurementsTable {
    /// One recorded measurement, as the table sees it.
    struct Sample: Sendable {
        let name: String
        let value: Double
        let unit: String
        let context: String
        let at: Date

        init(name: String, value: Double, unit: String, context: String = "", at: Date = Date()) {
            self.name = name
            self.value = value
            self.unit = unit
            self.context = context
            self.at = at
        }
    }

    enum Cell: Sendable {
        /// The latest value recorded under this measurement name.
        case latest(String)
        /// Fixed text, e.g. "n/a (one transaction per PTP/IP session)".
        case text(String)
        /// The BLE summary, one group per pairing context with samples: "connected: on no · asleep — · off — ·
        /// connected via another app: on yes; unpaired: on yes · …" from ble.advert.<state>.<pairing>.seen and
        /// ble.connected.<state>.<pairing>.seen (whether another app, Creators' App, held the camera), then the
        /// connection-event latency and the UUID — the owner's camera is paired with Creators' App, so advertising
        /// alone may not answer the proximity go/no-go, and one context must not hide another.
        case bleSummary
        case empty
    }

    struct Row: Sendable {
        let label: String
        let usb: Cell
        let ap: Cell
        let lan: Cell
    }

    static let header = ["Measurement", "USB-C (USB 2 iPhone)", "Wi-Fi, camera AP", "Wi-Fi, UniFi LAN"]

    static let onePTPIPTransaction = "n/a (one transaction per PTP/IP session)"

    /// The row labels are docs/spike-plan.md's, verbatim (backticks included).
    static let rows: [Row] = [
        Row(label: "Time to enumerate 200 files",
            usb: .latest("usb.catalog.complete"), ap: .latest("ptpip.ap.enumerate"), lan: .latest("ptpip.lan.enumerate")),
        Row(label: "Thumbnail fetch, average per item",
            usb: .latest("usb.thumb.avg"), ap: .latest("ptpip.ap.thumb.avg"), lan: .latest("ptpip.lan.thumb.avg")),
        Row(label: "ARW throughput, single file",
            usb: .latest("usb.download.throughput.serial"), ap: .latest("ptpip.ap.getObject.throughput"),
            lan: .latest("ptpip.lan.getObject.throughput")),
        Row(label: "ARW throughput, two in flight",
            usb: .latest("usb.download.throughput.parallel2"), ap: .text(onePTPIPTransaction), lan: .text(onePTPIPTransaction)),
        Row(label: "MP4 throughput (1 GB clip)",
            usb: .latest("usb.download.mp4"), ap: .latest("ptpip.ap.getObject.mp4"), lan: .latest("ptpip.lan.getObject.mp4")),
        Row(label: "`GetPartialObject` supported",
            usb: .latest("usb.getPartialObject.supported"), ap: .latest("ptpip.ap.getPartialObject.supported"),
            lan: .latest("ptpip.lan.getPartialObject.supported")),
        Row(label: "Resume after link drop verified",
            usb: .latest("usb.resume.verified"), ap: .latest("ptpip.ap.resume.verified"), lan: .latest("ptpip.lan.resume.verified")),
        Row(label: "`ObjectAdded` event received",
            usb: .latest("usb.event.objectAdded"), ap: .latest("ptpip.ap.event.objectAdded"), lan: .latest("ptpip.lan.event.objectAdded")),
        Row(label: "Session survives phone lock (seconds)",
            usb: .latest("usb.lifecycle.progressAfterBackground"), ap: .latest("ptpip.ap.lifecycle.progressAfterBackground"),
            lan: .latest("ptpip.lan.lifecycle.progressAfterBackground")),
        Row(label: "Camera battery used per 1 GB",
            usb: .latest("usb.battery.per1GB"), ap: .latest("ptpip.ap.battery.per1GB"), lan: .latest("ptpip.lan.battery.per1GB")),
        Row(label: "BLE: advertises when on / asleep / off; service UUID",
            usb: .bleSummary, ap: .empty, lan: .empty),
    ]

    /// The power states of the BLE row, in column order; the flags are `ble.advert.<state>.<pairing>.seen`.
    static let blePowerStates = ["on", "asleep", "off"]
    /// The pairing contexts of the BLE row (AdvertisementScanner.PairingContext), the owner's real setup first.
    static let blePairings = ["connected", "unlinked", "unpaired"]

    static let absent = "—"

    // MARK: - Rendering

    /// The plan's table, then "All measurements", then the device context. `serviceUUID` is the proximity filter
    /// chosen on the Bluetooth tab (@AppStorage "ble.serviceUUID").
    static func markdown(samples: [Sample], serviceUUID: String?, device: DeviceContext?, generatedAt: Date = Date()) -> String {
        let latest = latestByName(samples)
        var lines: [String] = []
        lines.append(tableLine(header))
        lines.append(tableLine(header.map { _ in "---" }))
        for row in rows {
            lines.append(tableLine([
                row.label,
                render(row.usb, latest: latest, serviceUUID: serviceUUID),
                render(row.ap, latest: latest, serviceUUID: serviceUUID),
                render(row.lan, latest: latest, serviceUUID: serviceUUID),
            ]))
        }

        lines.append("")
        lines.append("### All measurements")
        lines.append("")
        if samples.isEmpty {
            lines.append("No measurements recorded.")
        } else {
            let names = ["Name", "Latest value", "Unit", "Count", "Latest context"]
            lines.append(tableLine(names))
            lines.append(tableLine(names.map { _ in "---" }))
            var counts: [String: Int] = [:]
            for s in samples { counts[s.name, default: 0] += 1 }
            for name in latest.keys.sorted() {
                guard let s = latest[name] else { continue }
                lines.append(tableLine([
                    "`\(name)`",
                    formatValue(s.value, unit: s.unit),
                    s.unit,
                    "\(counts[name] ?? 0)",
                    s.context,
                ]))
            }
        }

        lines.append("")
        lines.append("### Device")
        lines.append("")
        if let device {
            lines.append(contentsOf: device.markdownLines)
        } else {
            lines.append("- Device context not recorded")
        }
        lines.append("- Table generated: \(DeviceContext.timestampFormatter.string(from: generatedAt))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The latest sample for each name. Samples are in recording order (SpikeLog appends), so the last one wins;
    /// a later timestamp also wins, in case a caller passes them unsorted.
    static func latestByName(_ samples: [Sample]) -> [String: Sample] {
        var out: [String: Sample] = [:]
        for s in samples {
            if let existing = out[s.name], existing.at > s.at { continue }
            out[s.name] = s
        }
        return out
    }

    static func render(_ cell: Cell, latest: [String: Sample], serviceUUID: String?) -> String {
        switch cell {
        case .latest(let name):
            guard let s = latest[name] else { return absent }
            return format(s.value, unit: s.unit)
        case .text(let text):
            return text
        case .bleSummary:
            func group(_ pairing: String?) -> String {
                let suffix = pairing.map { ".\($0)" } ?? ""
                var parts = blePowerStates.map { state -> String in
                    guard let s = latest["ble.advert.\(state)\(suffix).seen"] else { return "\(state) \(absent)" }
                    return "\(state) \(s.value != 0 ? "yes" : "no")"
                }
                let held = blePowerStates.compactMap { state -> String? in
                    guard let s = latest["ble.connected.\(state)\(suffix).seen"] else { return nil }
                    return "\(state) \(s.value != 0 ? "yes" : "no")"
                }
                if !held.isEmpty { parts.append("connected via another app: " + held.joined(separator: ", ")) }
                let text = parts.joined(separator: " · ")
                return pairing.map { "\($0): \(text)" } ?? text
            }
            let recorded = blePairings.filter { pairing in
                blePowerStates.contains { latest["ble.advert.\($0).\(pairing).seen"] != nil || latest["ble.connected.\($0).\(pairing).seen"] != nil }
            }
            var parts = [recorded.isEmpty ? group(nil) : recorded.map { group($0) }.joined(separator: "; ")]
            if let c = latest["ble.proximity.connectionEvent.latency"] {
                parts.append("connection event after \(format(c.value, unit: c.unit))")
            }
            let uuid = serviceUUID.flatMap { $0.isEmpty ? nil : $0 } ?? absent
            return (parts + ["UUID \(uuid)"]).joined(separator: " · ")
        case .empty:
            return ""
        }
    }

    /// "28.41 MB/s", "1.84 s", "yes". Booleans (unit "bool") read yes/no; everything else has 2 decimals.
    static func format(_ value: Double, unit: String) -> String {
        if unit == "bool" { return value != 0 ? "yes" : "no" }
        let number = formatValue(value, unit: unit)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// The number alone: "28.41", or "yes"/"no" for booleans.
    static func formatValue(_ value: Double, unit: String) -> String {
        if unit == "bool" { return value != 0 ? "yes" : "no" }
        guard value.isFinite else { return "\(value)" }
        return String(format: "%.2f", value)
    }

    /// One Markdown table row. Pipes are escaped and newlines flattened so free-text context can't break it.
    static func tableLine(_ cells: [String]) -> String {
        let escaped = cells.map { cell -> String in
            cell.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        return "| " + escaped.joined(separator: " | ") + " |"
    }
}

#if DEBUG
extension MeasurementsTable {
    /// Checks the renderer against the plan's table shape. Returns the failures (empty when all pass); run it on
    /// Linux with the scratch harness described in the spike report, or call it from a debugger.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let samples = [
            Sample(name: "usb.catalog.complete", value: 3.5, unit: "s", at: t0),
            Sample(name: "usb.catalog.complete", value: 1.837, unit: "s", context: "200 files", at: t0.addingTimeInterval(10)),
            Sample(name: "usb.getPartialObject.supported", value: 1, unit: "bool", at: t0),
            Sample(name: "ptpip.ap.getPartialObject.supported", value: 0, unit: "bool", at: t0),
            Sample(name: "ptpip.ap.getObject.throughput", value: 9.123, unit: "MB/s", context: "a|b\nc", at: t0),
            Sample(name: "ble.advert.on.unpaired.seen", value: 1, unit: "bool", at: t0),
            Sample(name: "ble.advert.off.unpaired.seen", value: 0, unit: "bool", at: t0),
        ]
        let md = markdown(samples: samples, serviceUUID: "8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF", device: nil, generatedAt: t0)
        let lines = md.components(separatedBy: "\n")

        expect(lines.first == "| Measurement | USB-C (USB 2 iPhone) | Wi-Fi, camera AP | Wi-Fi, UniFi LAN |", "header: \(lines.first ?? "nil")")
        expect(lines.count > 2 && lines[1] == "| --- | --- | --- | --- |", "separator row")
        expect(rows.count == 11, "11 rows like the plan, got \(rows.count)")
        expect(lines.contains("| Time to enumerate 200 files | 1.84 s | — | — |"), "latest value wins, absent is —")
        expect(lines.contains("| `GetPartialObject` supported | yes | no | — |"), "booleans read yes/no")
        expect(lines.contains("| ARW throughput, two in flight | — | \(onePTPIPTransaction) | \(onePTPIPTransaction) |"), "fixed text cells")
        expect(lines.contains("| ARW throughput, single file | — | 9.12 MB/s | — |"), "MB/s with 2 decimals")
        expect(lines.contains("| BLE: advertises when on / asleep / off; service UUID | unpaired: on yes · asleep — · off no · UUID 8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF |  |  |"), "BLE summary cell")
        expect(lines.contains("| `usb.catalog.complete` | 1.84 | s | 2 | 200 files |"), "all-measurements row with count and latest context")
        expect(lines.contains("| `ptpip.ap.getObject.throughput` | 9.12 | MB/s | 1 | a\\|b c |"), "context escaped")
        expect(md.contains("- Device context not recorded"), "device placeholder")

        let paired = markdown(samples: [
            Sample(name: "ble.advert.on.connected.seen", value: 0, unit: "bool", at: t0),
            Sample(name: "ble.connected.on.connected.seen", value: 1, unit: "bool", at: t0),
            Sample(name: "ble.connected.off.connected.seen", value: 0, unit: "bool", at: t0),
            // Saved later, as the runbook's order does: must not hide the connected context.
            Sample(name: "ble.advert.on.unpaired.seen", value: 1, unit: "bool", at: t0.addingTimeInterval(60)),
            Sample(name: "ble.connected.on.unpaired.seen", value: 0, unit: "bool", at: t0.addingTimeInterval(60)),
            Sample(name: "ble.proximity.connectionEvent.latency", value: 12.5, unit: "s", at: t0),
        ], serviceUUID: nil, device: nil, generatedAt: t0)
        expect(paired.contains("| BLE: advertises when on / asleep / off; service UUID | connected: on no · asleep — · off — · connected via another app: on yes, off no; unpaired: on yes · asleep — · off — · connected via another app: on no · connection event after 12.50 s · UUID — |  |  |"), "BLE cell for a camera held by Creators' App, per pairing context")

        let empty = markdown(samples: [], serviceUUID: nil, device: nil, generatedAt: t0)
        expect(empty.contains("| BLE: advertises when on / asleep / off; service UUID | on — · asleep — · off — · UUID — |  |  |"), "empty BLE cell")
        expect(empty.contains("No measurements recorded."), "empty all-measurements")
        return failures
    }
}
#endif
