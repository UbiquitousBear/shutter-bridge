// Decoding what `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)` hands back on iOS.
//
// The completion receives two `Data` values. Apple's documentation says only that "the block receives the
// response, data, and an error", and the Objective-C names (`responseData`, `ptpResponseData`) don't settle
// which is the data phase and whether either still carries its 12-byte container header. Spike day 4 records
// what iOS 27 actually does; until then this decoder accepts every plausible layout and reports which one it
// saw, so the answer is a log line rather than a guess baked into the code.

import Foundation

public enum PTPPassThrough {
    /// How the two `Data` values were laid out. Logged once per session for the findings page.
    public enum Layout: String, Sendable, Equatable, CaseIterable {
        /// (data-phase payload, response container): the documented-by-name reading.
        case dataThenResponse
        /// (response container, data-phase payload).
        case responseThenData
        /// (data container with header that we stripped, response container).
        case dataContainerThenResponse
        /// (response container, data container with header that we stripped).
        case responseThenDataContainer
        /// Both values concatenated hold a sequence of containers (data and response).
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
        /// Neither value, nor both together, held a response container.
        case noResponseContainer(firstPrefix: Data, secondPrefix: Data)
    }

    /// Decodes a pass-through reply to `command`. A data container header is recognised only if its length, type
    /// and operation code agree with `command` and its transaction ID matches the command's or the response's
    /// (ImageCaptureCore may renumber transactions), so a payload that merely starts with plausible bytes is
    /// never mistaken for a header.
    public static func decodeReply(_ first: Data, _ second: Data, for command: PTPContainer) throws -> Reply {
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
