import Foundation
import CLibUSB

/// Thin wrapper over the recovered Xone:3D vendor control-transfer protocol.
///
/// All operations are single USB control transfers on endpoint 0 with the
/// constants wValue=0x0100, wIndex=0x0001 (recovered from USBBridge.m).
final class USBBridge {

    static let vendorID: UInt16 = 0x0A4A    // Ploytec GmbH
    static let productID: UInt16 = 0xFF00   // Xone:3D

    // bmRequestType values
    private static let IN: UInt8  = 0xC2    // IN  | Vendor | Endpoint
    private static let OUT: UInt8 = 0x42    // OUT | Vendor | Endpoint
    private static let W_VALUE: UInt16 = 0x0100
    private static let W_INDEX: UInt16 = 0x0001
    private static let TIMEOUT: UInt32 = 2000

    // bRequest opcodes
    private static let REQ_GET_VERSION: UInt8   = 0x00
    private static let REQ_READ_ROUTING: UInt8  = 0x01
    private static let REQ_SEND_ROUTING: UInt8  = 0x02
    private static let REQ_READ_FIRMWARE: UInt8 = 0x06

    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?

    enum USBError: Error, CustomStringConvertible {
        case initFailed(Int32)
        case notFound
        case accessDenied
        case transfer(String, Int32)

        var description: String {
            switch self {
            case .initFailed(let c): return "libusb init failed (\(c))"
            case .notFound:
                return "Xone:3D not found (VID 0x0A4A / PID 0xFF00). " +
                       "Plugged in and powered on?"
            case .accessDenied:
                return "Access denied — macOS has likely claimed the device as " +
                       "a USB-audio interface. See the report's 'Running on M1' notes."
            case .transfer(let dir, let c):
                return "USB \(dir) transfer failed (\(c))"
            }
        }
    }

    var isOpen: Bool { handle != nil }

    func open() throws {
        close()
        var c: OpaquePointer?
        let r = libusb_init(&c)
        if r != 0 { throw USBError.initFailed(r) }
        ctx = c
        guard let h = libusb_open_device_with_vid_pid(ctx,
                                                      USBBridge.vendorID,
                                                      USBBridge.productID) else {
            // Device may be absent, or present but busy/denied.
            throw USBError.notFound
        }
        handle = h
    }

    func close() {
        if let h = handle { libusb_close(h); handle = nil }
        if let c = ctx { libusb_exit(c); ctx = nil }
    }

    deinit { close() }

    // MARK: - primitives

    private func controlIn(_ bRequest: UInt8, length: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: length)
        let n = buf.withUnsafeMutableBufferPointer { p in
            libusb_control_transfer(handle, USBBridge.IN, bRequest,
                                    USBBridge.W_VALUE, USBBridge.W_INDEX,
                                    p.baseAddress, UInt16(length), USBBridge.TIMEOUT)
        }
        if n < 0 {
            if n == LIBUSB_ERROR_ACCESS.rawValue { throw USBError.accessDenied }
            throw USBError.transfer("IN", n)
        }
        return Array(buf.prefix(Int(n)))
    }

    private func controlOut(_ bRequest: UInt8, data: [UInt8]) throws {
        var d = data
        let count = UInt16(d.count)
        let n = d.withUnsafeMutableBufferPointer { p in
            libusb_control_transfer(handle, USBBridge.OUT, bRequest,
                                    USBBridge.W_VALUE, USBBridge.W_INDEX,
                                    p.baseAddress, count, USBBridge.TIMEOUT)
        }
        if n < 0 {
            if n == LIBUSB_ERROR_ACCESS.rawValue { throw USBError.accessDenied }
            throw USBError.transfer("OUT", n)
        }
    }

    // MARK: - high-level operations

    func getVersion() throws -> (raw: [UInt8], text: String) {
        let raw = try controlIn(USBBridge.REQ_GET_VERSION, length: 16)
        let bytes = raw.prefix { $0 != 0 }
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw, text)
    }

    func readRouting() throws -> UInt16 {
        let b = try controlIn(USBBridge.REQ_READ_ROUTING, length: 2)
        guard b.count >= 2 else { throw USBError.transfer("IN", -99) }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)   // little-endian
    }

    func sendRouting(_ word: UInt16) throws {
        try controlOut(USBBridge.REQ_SEND_ROUTING,
                       data: [UInt8(word & 0xFF), UInt8(word >> 8)])
    }

    func readFirmware(length: Int) throws -> [UInt8] {
        try controlIn(USBBridge.REQ_READ_FIRMWARE, length: length)
    }
}
