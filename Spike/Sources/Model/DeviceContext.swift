import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Which phone, which iOS build and which spike build a set of numbers came from. Logged once per launch and put
/// at the top of every export, so a measurements table pasted into the findings page carries its provenance.
///
/// Foundation-only on purpose (no UIKit): it typechecks on Linux with `/tmp/tools/typecheck.sh`, and the
/// Darwin-only reads are behind `#if canImport(Darwin)`.
struct DeviceContext: Codable, Sendable, Equatable {
    /// Hardware identifier from `utsname.machine`, e.g. "iPhone17,3"; the Simulator reports its simulated model.
    var modelIdentifier: String
    /// "iOS", or the platform the code is running on.
    var systemName: String
    /// "27.0.1", from `ProcessInfo.operatingSystemVersion`.
    var systemVersion: String
    /// "24A5300a": the `kern.osversion` sysctl, or parsed from `operatingSystemVersionString`; "unknown" if neither.
    var systemBuild: String
    /// CFBundleShortVersionString and CFBundleVersion of the spike app.
    var appVersion: String
    var appBuild: String
    /// Low Power Mode stops background Bluetooth scanning and may end continued-processing tasks early.
    var lowPowerMode: Bool
    var thermalState: String
    var capturedAt: Date

    static func current(bundle: Bundle = .main, now: Date = Date()) -> DeviceContext {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let version = v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        var lowPower = false
        var thermal = "n/a"
        #if canImport(Darwin)
        lowPower = info.isLowPowerModeEnabled
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        #endif
        return DeviceContext(
            modelIdentifier: machineIdentifier(),
            systemName: platformName,
            systemVersion: version,
            systemBuild: systemBuildNumber(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            lowPowerMode: lowPower,
            thermalState: thermal,
            capturedAt: now)
    }

    /// One line for the log: "iPhone17,3 · iOS 27.0.1 (24A5300a) · spike 0.1 (1) · Low Power Mode off · thermal nominal".
    var summary: String {
        "\(modelIdentifier) · \(systemName) \(systemVersion) (\(systemBuild)) · spike \(appVersion) (\(appBuild))"
            + " · Low Power Mode \(lowPowerMode ? "on" : "off") · thermal \(thermalState)"
    }

    /// Markdown bullet lines for the measurements export.
    var markdownLines: [String] {
        [
            "- Device: \(modelIdentifier)",
            "- \(systemName): \(systemVersion) (build \(systemBuild))",
            "- Spike app: \(appVersion) (\(appBuild))",
            "- Low Power Mode: \(lowPowerMode ? "on" : "off"); thermal state: \(thermalState)",
            "- Captured: \(Self.timestampFormatter.string(from: capturedAt))",
        ]
    }

    /// "2026-11-13 16:02:11 +0100": local time with the offset, so findings from different days line up.
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private static var platformName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "unknown OS"
        #endif
    }

    /// `utsname.machine` ("iPhone17,3"). On the Simulator that is the Mac's CPU, so prefer the simulated model.
    static func machineIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated + " (Simulator)"
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let machine: String = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// The OS build ("24A5300a"). `kern.osversion` is the documented BSD sysctl for it; the fallback parses the
    /// "(Build …)" part of the human-readable version string, which Apple says is not meant for parsing, so it
    /// is only used when the sysctl fails.
    static func systemBuildNumber() -> String {
        #if canImport(Darwin)
        // verify on day 1: sysctlbyname is documented for macOS; it is in the iOS SDK's <sys/sysctl.h> and
        // "kern.osversion" is expected to return the iOS build. The log line at launch shows what it returned.
        var size: Int = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 {
                let bytes: [UInt8] = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let build = String(decoding: bytes, as: UTF8.self)
                if !build.isEmpty { return build }
            }
        }
        #endif
        return buildFromVersionString(ProcessInfo.processInfo.operatingSystemVersionString) ?? "unknown"
    }

    /// "Version 27.0 (Build 24A5300a)" → "24A5300a".
    static func buildFromVersionString(_ s: String) -> String? {
        guard let start = s.range(of: "Build ") else { return nil }
        let rest = s[start.upperBound...]
        let build = rest.prefix { $0 != ")" && $0 != " " }
        return build.isEmpty ? nil : String(build)
    }
}
