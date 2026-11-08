// Masked hex for logs: bytes up to 0x0F show, larger bytes don't. Flags and structure stay visible; text and large binary
// values (a serial number, part of an address, a password) can't. The spike logged every CC value this way except CC06,
// CC07 and CC0C, which are logged as lengths only.

public enum SonyMasking {
    /// Bytes up to 0x0F as two hex digits, larger bytes as "··", at most 64 bytes and then "… (N B)", "0 B" for none:
    /// "00 01 ·· 0A".
    public static func maskedHex(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "0 B" }
        let shown = bytes.prefix(64).map(maskedByte).joined(separator: " ")
        return bytes.count > 64 ? shown + " … (\(bytes.count) B)" : shown
    }

    public static func maskedByte(_ byte: UInt8) -> String {
        guard byte <= 0x0F else { return "··" }
        return "0" + String(byte, radix: 16, uppercase: true)
    }
}
