import CameraTransport
import Catalogue
import Foundation

/// Works out the catalogue's key for a connected camera (backlog sections 2 and 4: an open point in MSC). The app's
/// closure reads the link's key material (`USBLink.cameraKeyMaterial()`, Apple-only) and hands it to
/// `CameraKeys.key(for:material:)`.
public typealias CameraKeying = @Sendable (CameraDescriptor, any CameraLink) async -> CameraKey

/// The rule for the catalogue's camera key, pure so it is tested on Linux. **Unverified, and provisional as the
/// backlog says** (sections 2 and 4, *the camera key in MSC*):
///
/// - **MTP:** the device's UUID string (`USBCameraKeyMaterial`), stable across sessions and replugs on the bench.
///   It embeds what looks like the camera's USB serial, so it is hashed (SHA-256) before it becomes a key, as
///   `CameraKey` asks: the raw value never reaches the catalogue, a log or the screen.
/// - **MSC:** the link gives no material (the device is named after the card's volume, answers no PTP, and whether
///   its UUID carries the serial isn't recorded), so the key is the mode and the volume name ("Untitled"), hashed
///   the same way. Every card with that name shares the key until week 1 settles one both modes can share, so a file
///   imported in MTP shows as new in MSC and the other way round; the engine's diff still never imports a file twice
///   *within* a mode.
/// - **Remote Shoot:** nothing is imported, so the MSC-style fallback is fine.
public enum CameraKeys {
    /// The key for `descriptor`, from the link's material when it has some (MTP), else from the mode and name.
    public static func key(for descriptor: CameraDescriptor, material: String?) -> CameraKey {
        if let material, !material.isEmpty {
            return CameraKey(rawValue: "usb-device:" + SHA256Digest.hex(of: Data(material.utf8)))
        }
        let mode: String
        switch descriptor.mode {
        case .usb(.massStorage): mode = "usb-msc"
        case .usb(.mtp): mode = "usb-mtp"
        case .usb(.remoteShoot): mode = "usb-remote-shoot"
        case .wifi: mode = "wifi"
        }
        return CameraKey(rawValue: mode + "-name:" + SHA256Digest.hex(of: Data(descriptor.name.utf8)))
    }

    /// A keying that uses the descriptor alone: for tests and previews, and for links with no key material.
    public static let fromDescriptor: CameraKeying = { descriptor, _ in key(for: descriptor, material: nil) }
}

/// SHA-256 (FIPS 180-4), for hashing key material on every platform: CryptoKit is Apple-only and the workspace takes
/// no third-party dependencies. Not used for anything secret beyond keeping a serial out of the catalogue's keys.
enum SHA256Digest {
    static func hex(of data: Data) -> String {
        digest(of: data).map { byte in
            let s = String(byte, radix: 16)
            return byte < 16 ? "0" + s : s
        }.joined()
    }

    static func digest(of data: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0 ..< 16 {
                let b = chunk + i * 4
                w[i] = UInt32(message[b]) << 24 | UInt32(message[b + 1]) << 16 | UInt32(message[b + 2]) << 8
                    | UInt32(message[b + 3])
            }
            for i in 16 ..< 64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0 ..< 64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }
        return h.flatMap { word in (0 ..< 4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
