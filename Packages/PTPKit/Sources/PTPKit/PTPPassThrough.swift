// Decoding what `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)` hands back on iOS.
//
// The completion receives two `Data` values. Apple's documentation says only that "the block receives the
// response, data, and an error", and the Objective-C names (`responseData`, `ptpResponseData`) don't settle
// which is the data phase and whether either still carries its 12-byte container header. On iOS 27.2 with the
// α7C II over USB in MTP, ImageCaptureCore produced `dataThenResponse`: the first value is the bare data phase and
// the second the 12-byte response container, with the transaction ID renumbered. The other layouts were never
// produced. They stay decodable, so an unexpected layout is decoded and logged rather than lost.

import Foundation

public enum PTPPassThrough {
    /// How the two `Data` values were laid out. Logged once per session for the findings page.
    public enum Layout: String, Sendable, Equatable, CaseIterable {
        /// (data-phase payload, response container): the documented-by-name reading.
        ///
        /// The layout ImageCaptureCore produced (unverified: spike, MTP over USB. GetStorageIDs on 1 Nov 19:19:37
        /// gave 8 B + 12 B, response transaction 801 for our 1. GetDeviceInfo on 5 Nov 22:38 gave 247 B + 12 B,
        /// 1677 for our 1). It stays `unverified`: the fixtures hold only `reply.data`, saved after decoding, so no fixture holds the two raw
        /// values; `passThroughGolden` checks only that the captured data phases decode as bare payloads.
        case dataThenResponse
        /// (response container, data-phase payload).
        ///
        /// Never produced by ImageCaptureCore in the spike; kept, behind its test, so an unexpected layout still decodes and is logged.
        case responseThenData
        /// (data container with header that we stripped, response container).
        ///
        /// Never produced by ImageCaptureCore in the spike; kept, behind its test, so an unexpected layout still decodes and is logged.
        case dataContainerThenResponse
        /// (response container, data container with header that we stripped).
        ///
        /// Never produced by ImageCaptureCore in the spike; kept, behind its test, so an unexpected layout still decodes and is logged.
        case responseThenDataContainer
        /// Both values concatenated hold a sequence of containers (data and response).
        ///
        /// Never produced by ImageCaptureCore in the spike; kept, behind its test, so an unexpected layout still decodes and is logged.
        case concatenatedContainers
    }

    public struct Reply: Equatable, Sendable {
        public var response: PTPContainer
        /// The data-phase payload with any container header removed. Empty when the operation has no data phase.
        public var data: Data
        public var layout: Layout

        public var responseCode: PTPResponseCode { response.responseCode }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Both values were empty: ImageCaptureCore's "no answer". It completes a request that way, with no error,
        /// after about 60 s when the camera hasn't answered (unverified: spike, MTP whole-card GetObjectPropList on
        /// 1 Nov, 60.47 s), and the same at once when the cable is pulled mid-request (1 Nov). In MSC, where the
        /// camera answers no PTP, a request didn't complete at all (GetObjectHandles not within the spike's 120 s,
        /// 1 Nov 19:09–19:17), so the caller still needs its own timeout. The decoder can't tell these apart: the
        /// caller uses the elapsed time and ImageCaptureCore's removal callback. Not a malformed reply.
        case noAnswer
        /// Neither value, nor both together, held a response container (at least one value was non-empty).
        case noResponseContainer(firstPrefix: Data, secondPrefix: Data)
    }

    /// Decodes a pass-through reply to `command`. A data container header is recognised only if its length, type
    /// and operation code agree with `command` and its transaction ID matches the command's or the response's
    /// (ImageCaptureCore may renumber transactions), so a payload that merely starts with plausible bytes is
    /// never mistaken for a header. Throws `.noAnswer` for two empty values, `.noResponseContainer` for anything
    /// else it can't read.
    public static func decodeReply(_ first: Data, _ second: Data, for command: PTPContainer) throws -> Reply {
        if first.isEmpty && second.isEmpty { throw Failure.noAnswer }
        if let response = responseContainer(second) {
            let (payload, stripped) = strippingDataHeader(first, for: command, responseTX: response.transactionID)
            return Reply(response: response, data: payload, layout: stripped ? .dataContainerThenResponse : .dataThenResponse)
        }
        if let response = responseContainer(first) {
            let (payload, stripped) = strippingDataHeader(second, for: command, responseTX: response.transactionID)
            return Reply(response: response, data: payload, layout: stripped ? .responseThenDataContainer : .responseThenData)
        }
        if let all = try? PTPContainer.decodeAll(first + second),
           let response = all.last(where: { $0.type == .response }) {
            let payload = all.filter { $0.type == .data }.reduce(into: Data()) { $0.append($1.payload) }
            return Reply(response: response, data: payload, layout: .concatenatedContainers)
        }
        throw Failure.noResponseContainer(firstPrefix: Data(first.prefix(32)), secondPrefix: Data(second.prefix(32)))
    }

    /// A buffer that is exactly one response container (length field equal to the buffer size, at most five
    /// parameters).
    static func responseContainer(_ data: Data) -> PTPContainer? {
        guard data.count >= PTPContainer.headerLength, data.count <= PTPContainer.headerLength + 5 * 4,
              let (c, used) = try? PTPContainer.decode(data), used == data.count, c.type == .response else { return nil }
        return c
    }

    static func strippingDataHeader(_ data: Data, for command: PTPContainer, responseTX: UInt32) -> (Data, Bool) {
        guard data.count >= PTPContainer.headerLength else { return (data, false) }
        var r = PTPReader(data)
        guard let length = try? r.u32(), let type = try? r.u16(), let code = try? r.u16(), let tx = try? r.u32(),
              Int(length) == data.count, type == PTPContainerType.data.rawValue, code == command.code,
              tx == command.transactionID || tx == responseTX else { return (data, false) }
        return (Data(data.dropFirst(PTPContainer.headerLength)), true)
    }
}
