import Foundation
import CoreBluetooth
import LibDiveComputer

// MARK: - Ioctl Decoding Helpers

/// Replicates the C macros from ioctl.h and ble.h that Swift can't import.
private enum Ioctl {
    // Direction bits
    static let dirRead: UInt32  = 1
    static let dirWrite: UInt32 = 2

    // BLE ioctl type = 'b'
    static let typeBLE: UInt32 = 0x62

    // BLE ioctl numbers
    static let nrName: UInt32       = 0
    static let nrPinCode: UInt32    = 1
    static let nrAccessCode: UInt32 = 2

    // Decode an ioctl request code
    static func dir(_ request: UInt32) -> UInt32  { (request >> 30) & 0x03 }
    static func type(_ request: UInt32) -> UInt32 { (request >>  8) & 0xFF }
    static func nr(_ request: UInt32) -> UInt32   { (request >>  0) & 0xFF }
}

// MARK: - BLETransport

/// Bridges a connected CoreBluetooth peripheral into a libdivecomputer
/// `dc_iostream_t` via the custom iostream API (`dc_custom_open`).
///
/// Threading model:
/// - libdivecomputer calls our C callbacks from a background DispatchQueue
/// - CoreBluetooth delegate callbacks arrive on the main queue
/// - We use semaphores to block the background thread until BLE completes
/// - The receive buffer is protected by NSLock for thread safety
class BLETransport: NSObject {

    // MARK: - Properties

    fileprivate let peripheral: CBPeripheral
    fileprivate let deviceName: String
    fileprivate var txCharacteristic: CBCharacteristic?
    fileprivate var rxCharacteristic: CBCharacteristic?

    /// The libdivecomputer custom iostream created by this transport.
    private(set) var iostream: OpaquePointer?  // dc_iostream_t*

    // Thread-safe receive buffer
    private var receiveBuffer = Data()
    private let bufferLock = NSLock()
    fileprivate let dataAvailable = DispatchSemaphore(value: 0)

    // Write synchronization
    fileprivate let writeComplete = DispatchSemaphore(value: 0)
    fileprivate var writeError: Error?
    fileprivate var writeType: CBCharacteristicWriteType = .withResponse

    // Timeout (milliseconds): <0 = blocking, 0 = non-blocking, >0 = timeout
    fileprivate var readTimeoutMs: Int = 5000

    // Connection state
    fileprivate(set) var isClosed = false

    // BLE access code (Shearwater uses this for authentication)
    fileprivate var accessCode = Data()

    // Unmanaged pointer for C callback userdata
    private var unmanagedSelf: Unmanaged<BLETransport>?

    // Setup completion
    private var setupCompletion: ((Bool, String?) -> Void)?

    // Service discovery state tracking
    private var pendingServiceCount = 0

    // MARK: - Init

    init(peripheral: CBPeripheral, name: String) {
        self.peripheral = peripheral
        self.deviceName = name
        super.init()
    }

    deinit {
        close()
    }

    // MARK: - Setup (Service/Characteristic Discovery)

    /// Discovers BLE services and characteristics, subscribes to notifications,
    /// and creates the libdivecomputer iostream. Calls completion on the main queue.
    func setup(context: OpaquePointer?, completion: @escaping (Bool, String?) -> Void) {
        self.setupCompletion = completion
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    // MARK: - iostream Creation

    /// Creates the dc_iostream_t using dc_custom_open after characteristics are ready.
    private func createIOStream(context: OpaquePointer?) -> Bool {
        // Retain self for the lifetime of the C callbacks
        unmanagedSelf = Unmanaged.passRetained(self)
        let userdata = unmanagedSelf!.toOpaque()

        var callbacks = dc_custom_cbs_t()
        callbacks.set_timeout = bleSetTimeout
        callbacks.set_break   = bleSetBreak
        callbacks.set_dtr     = bleSetDTR
        callbacks.set_rts     = bleSetRTS
        callbacks.get_lines   = bleGetLines
        callbacks.get_available = bleGetAvailable
        callbacks.configure   = bleConfigure
        callbacks.poll        = blePoll
        callbacks.read        = bleRead
        callbacks.write       = bleWrite
        callbacks.ioctl       = bleIoctl
        callbacks.flush       = bleFlush
        callbacks.purge       = blePurge
        callbacks.sleep       = bleSleep
        callbacks.close       = bleClose

        var stream: OpaquePointer?
        let status = dc_custom_open(&stream, context, DC_TRANSPORT_BLE, &callbacks, userdata)

        guard status == DC_STATUS_SUCCESS, stream != nil else {
            NSLog("[BLETransport] dc_custom_open failed: \(status.rawValue)")
            unmanagedSelf?.release()
            unmanagedSelf = nil
            return false
        }

        self.iostream = stream
        NSLog("[BLETransport] iostream created successfully")
        return true
    }

    // MARK: - Close

    func close() {
        guard !isClosed else { return }
        isClosed = true

        // Unblock any waiting reads
        dataAvailable.signal()

        // Release the retained self
        if let unmanaged = unmanagedSelf {
            unmanaged.release()
            unmanagedSelf = nil
        }

        iostream = nil
        NSLog("[BLETransport] closed")
    }

    // MARK: - Buffer Operations (thread-safe)

    private func appendToBuffer(_ data: Data) {
        bufferLock.lock()
        receiveBuffer.append(data)
        bufferLock.unlock()
        dataAvailable.signal()
    }

    fileprivate var bufferedByteCount: Int {
        bufferLock.lock()
        let count = receiveBuffer.count
        bufferLock.unlock()
        return count
    }

    fileprivate func drainBuffer(maxBytes: Int) -> Data {
        bufferLock.lock()
        let count = min(maxBytes, receiveBuffer.count)
        let data = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        bufferLock.unlock()
        return Data(data)
    }

    fileprivate func clearBuffer() {
        bufferLock.lock()
        receiveBuffer.removeAll()
        bufferLock.unlock()
    }

    /// Drain any pending semaphore signals and clear the buffer.
    /// Call before starting a new logical operation (e.g., download)
    /// to prevent stale data from a previous exchange.
    func prepareForNewOperation() {
        clearBuffer()
        // Drain any pending semaphore signals so reads block properly
        while dataAvailable.wait(timeout: .now()) == .success {}
        NSLog("[BLETransport] Buffer and semaphore reset for new operation")
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            NSLog("[BLETransport] Service discovery error: \(error)")
            setupCompletion?(false, "Service discovery failed: \(error.localizedDescription)")
            setupCompletion = nil
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            NSLog("[BLETransport] No services found")
            setupCompletion?(false, "No BLE services found on device")
            setupCompletion = nil
            return
        }

        NSLog("[BLETransport] Discovered \(services.count) services")
        pendingServiceCount = services.count
        for service in services {
            NSLog("[BLETransport]   Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            NSLog("[BLETransport] Characteristic discovery error for \(service.uuid): \(error)")
        }

        if let characteristics = service.characteristics {
            for char in characteristics {
                NSLog("[BLETransport]   Char: \(char.uuid) props: \(char.properties.rawValue)")

                // Look for a notify characteristic (RX — data from device)
                if rxCharacteristic == nil && char.properties.contains(.notify) {
                    rxCharacteristic = char
                    NSLog("[BLETransport]   → RX (notify): \(char.uuid)")
                }

                // Look for a writable characteristic (TX — data to device)
                // Prefer writeWithoutResponse for BLE UART — most dive computers
                // (including Shearwater) expect this for throughput and may not
                // properly acknowledge write-with-response.
                if txCharacteristic == nil {
                    if char.properties.contains(.writeWithoutResponse) {
                        txCharacteristic = char
                        writeType = .withoutResponse
                        NSLog("[BLETransport]   → TX (write without response): \(char.uuid)")
                    } else if char.properties.contains(.write) {
                        txCharacteristic = char
                        writeType = .withResponse
                        NSLog("[BLETransport]   → TX (write with response): \(char.uuid)")
                    }
                }
            }
        }

        pendingServiceCount -= 1
        if pendingServiceCount <= 0 {
            finishCharacteristicDiscovery()
        }
    }

    private func finishCharacteristicDiscovery() {
        guard let rx = rxCharacteristic else {
            NSLog("[BLETransport] No RX (notify) characteristic found")
            setupCompletion?(false, "No notify characteristic found on device")
            setupCompletion = nil
            return
        }

        guard txCharacteristic != nil else {
            NSLog("[BLETransport] No TX (write) characteristic found")
            setupCompletion?(false, "No write characteristic found on device")
            setupCompletion = nil
            return
        }

        // Subscribe to notifications on RX
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("[BLETransport] Notification subscription error: \(error)")
            setupCompletion?(false, "Failed to subscribe to notifications: \(error.localizedDescription)")
            setupCompletion = nil
            return
        }

        NSLog("[BLETransport] Subscribed to notifications on \(characteristic.uuid)")

        // All ready — create the iostream
        // We pass nil for context here; the plugin will provide its context to dc_device_open
        let success = createIOStream(context: nil)
        setupCompletion?(success, success ? nil : "Failed to create iostream")
        setupCompletion = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        appendToBuffer(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeError = error
        writeComplete.signal()
    }
}

// MARK: - C Callback Implementations
//
// These are top-level functions with @convention(c) signatures matching dc_custom_cbs_t.
// They extract the BLETransport from the userdata pointer and delegate to instance methods.

private func transport(from userdata: UnsafeMutableRawPointer?) -> BLETransport? {
    guard let ptr = userdata else { return nil }
    return Unmanaged<BLETransport>.fromOpaque(ptr).takeUnretainedValue()
}

private let bleSetTimeout: @convention(c) (UnsafeMutableRawPointer?, Int32) -> dc_status_t = { userdata, timeout in
    guard let t = transport(from: userdata) else { return DC_STATUS_IO }
    t.readTimeoutMs = Int(timeout)
    return DC_STATUS_SUCCESS
}

private let bleSetBreak: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> dc_status_t = { _, _ in
    // Not applicable to BLE — silently accept
    return DC_STATUS_SUCCESS
}

private let bleSetDTR: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> dc_status_t = { _, _ in
    return DC_STATUS_SUCCESS
}

private let bleSetRTS: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> dc_status_t = { _, _ in
    return DC_STATUS_SUCCESS
}

private let bleGetLines: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> dc_status_t = { _, value in
    value?.pointee = 0
    return DC_STATUS_SUCCESS
}

private let bleGetAvailable: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int>?) -> dc_status_t = { userdata, value in
    guard let t = transport(from: userdata), let value = value else { return DC_STATUS_IO }
    value.pointee = t.bufferedByteCount
    return DC_STATUS_SUCCESS
}

private let bleConfigure: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, dc_parity_t, dc_stopbits_t, dc_flowcontrol_t) -> dc_status_t = { _, _, _, _, _, _ in
    // BLE has no serial port settings — silently accept
    return DC_STATUS_SUCCESS
}

private let blePoll: @convention(c) (UnsafeMutableRawPointer?, Int32) -> dc_status_t = { userdata, timeout in
    guard let t = transport(from: userdata) else { return DC_STATUS_IO }
    if t.isClosed { return DC_STATUS_IO }

    // If data already available, return immediately
    if t.bufferedByteCount > 0 { return DC_STATUS_SUCCESS }

    // Wait for data
    let timeoutMs = Int(timeout)
    let result: DispatchTimeoutResult
    if timeoutMs < 0 {
        t.dataAvailable.wait()
        result = .success
    } else if timeoutMs == 0 {
        result = t.bufferedByteCount > 0 ? .success : .timedOut
    } else {
        result = t.dataAvailable.wait(timeout: .now() + .milliseconds(timeoutMs))
    }

    if t.isClosed { return DC_STATUS_IO }
    return result == .success ? DC_STATUS_SUCCESS : DC_STATUS_TIMEOUT
}

private let bleRead: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?) -> dc_status_t = { userdata, data, size, actual in
    guard let t = transport(from: userdata), let data = data, let actual = actual else {
        return DC_STATUS_IO
    }
    if t.isClosed { return DC_STATUS_IO }

    actual.pointee = 0
    var totalRead = 0
    let deadline: DispatchTime
    let timeoutMs = t.readTimeoutMs

    if timeoutMs < 0 {
        deadline = .distantFuture
    } else if timeoutMs == 0 {
        // Non-blocking: take whatever is available
        let chunk = t.drainBuffer(maxBytes: size)
        if !chunk.isEmpty {
            chunk.copyBytes(to: data.assumingMemoryBound(to: UInt8.self), count: chunk.count)
            actual.pointee = chunk.count
        }
        return DC_STATUS_SUCCESS
    } else {
        deadline = .now() + .milliseconds(timeoutMs)
    }

    // Blocking or timeout read: wait for at least SOME data, then return
    // what's available (like POSIX read on a socket — returns up to `size`
    // bytes, not exactly `size` bytes).
    while totalRead < size {
        // Check if we already have data buffered
        let available = t.bufferedByteCount
        if available > 0 {
            let needed = size - totalRead
            let chunk = t.drainBuffer(maxBytes: needed)
            let dest = data.assumingMemoryBound(to: UInt8.self).advanced(by: totalRead)
            chunk.copyBytes(to: dest, count: chunk.count)
            totalRead += chunk.count
            // Return immediately with whatever we got — don't block
            // waiting for more. The caller will call read again if needed.
            break
        }

        if t.isClosed { break }

        // No data at all yet — wait for the first notification
        let remaining = deadline == .distantFuture ? .distantFuture : deadline
        let waitResult = t.dataAvailable.wait(timeout: remaining)

        if t.isClosed { break }
        if waitResult == .timedOut { break }
        // Data arrived — loop back to drain it
    }

    actual.pointee = totalRead
    return totalRead > 0 ? DC_STATUS_SUCCESS : DC_STATUS_TIMEOUT
}

private let bleWrite: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int, UnsafeMutablePointer<Int>?) -> dc_status_t = { userdata, data, size, actual in
    guard let t = transport(from: userdata), let data = data, let actual = actual else {
        return DC_STATUS_IO
    }
    if t.isClosed { return DC_STATUS_IO }

    let writeData = Data(bytes: data, count: size)
    let mtu = t.peripheral.maximumWriteValueLength(for: t.writeType)
    var offset = 0

    while offset < writeData.count {
        let chunkSize = min(mtu, writeData.count - offset)
        let chunk = writeData.subdata(in: offset..<(offset + chunkSize))

        if t.writeType == .withResponse {
            // Synchronously dispatch write and wait for device acknowledgment
            let writeDone = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                t.peripheral.writeValue(chunk, for: t.txCharacteristic!, type: .withResponse)
                writeDone.signal()
            }
            writeDone.wait()

            // Wait for write completion callback from CoreBluetooth
            let result = t.writeComplete.wait(timeout: .now() + .seconds(5))
            if result == .timedOut {
                NSLog("[BLETransport] Write timeout")
                actual.pointee = offset
                return DC_STATUS_TIMEOUT
            }
            if t.writeError != nil {
                NSLog("[BLETransport] Write error: \(t.writeError!)")
                actual.pointee = offset
                return DC_STATUS_IO
            }
        } else {
            // writeWithoutResponse: synchronously dispatch to main queue,
            // wait for it to actually execute before continuing
            let writeDone = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                t.peripheral.writeValue(chunk, for: t.txCharacteristic!, type: .withoutResponse)
                writeDone.signal()
            }
            writeDone.wait()
        }

        offset += chunkSize
    }

    actual.pointee = size
    return DC_STATUS_SUCCESS
}

private let bleIoctl: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?, Int) -> dc_status_t = { userdata, request, data, size in
    guard let t = transport(from: userdata) else { return DC_STATUS_IO }

    let type = Ioctl.type(request)
    let nr = Ioctl.nr(request)
    let dir = Ioctl.dir(request)

    // Only handle BLE ioctls
    guard type == Ioctl.typeBLE else {
        return DC_STATUS_UNSUPPORTED
    }

    switch nr {
    case Ioctl.nrName:
        // DC_IOCTL_BLE_GET_NAME — return device name as C string
        guard dir & Ioctl.dirRead != 0, let data = data, size > 0 else {
            return DC_STATUS_INVALIDARGS
        }
        let name = t.deviceName
        let cStr = name.utf8CString
        let copyLen = min(cStr.count, size) // includes null terminator
        cStr.withUnsafeBufferPointer { buffer in
            data.copyMemory(from: buffer.baseAddress!, byteCount: copyLen)
        }
        return DC_STATUS_SUCCESS

    case Ioctl.nrAccessCode where dir & Ioctl.dirRead != 0:
        // DC_IOCTL_BLE_GET_ACCESSCODE — return stored access code
        guard let data = data else { return DC_STATUS_INVALIDARGS }
        let code = t.accessCode
        if code.isEmpty {
            // Return zero-length — no access code stored
            return DC_STATUS_SUCCESS
        }
        let copyLen = min(code.count, size)
        code.withUnsafeBytes { buffer in
            data.copyMemory(from: buffer.baseAddress!, byteCount: copyLen)
        }
        return DC_STATUS_SUCCESS

    case Ioctl.nrAccessCode where dir & Ioctl.dirWrite != 0:
        // DC_IOCTL_BLE_SET_ACCESSCODE — store access code from device
        guard let data = data, size > 0 else { return DC_STATUS_INVALIDARGS }
        t.accessCode = Data(bytes: data, count: size)
        NSLog("[BLETransport] Access code set (\(size) bytes)")
        return DC_STATUS_SUCCESS

    default:
        NSLog("[BLETransport] Unsupported ioctl: type=0x\(String(type, radix: 16)) nr=\(nr) dir=\(dir)")
        return DC_STATUS_UNSUPPORTED
    }
}

private let bleFlush: @convention(c) (UnsafeMutableRawPointer?) -> dc_status_t = { _ in
    return DC_STATUS_SUCCESS
}

private let blePurge: @convention(c) (UnsafeMutableRawPointer?, dc_direction_t) -> dc_status_t = { userdata, direction in
    guard let t = transport(from: userdata) else { return DC_STATUS_IO }
    // Clear receive buffer on input purge
    if direction.rawValue & DC_DIRECTION_INPUT.rawValue != 0 {
        t.clearBuffer()
    }
    return DC_STATUS_SUCCESS
}

private let bleSleep: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> dc_status_t = { _, milliseconds in
    usleep(UInt32(milliseconds) * 1000)
    return DC_STATUS_SUCCESS
}

private let bleClose: @convention(c) (UnsafeMutableRawPointer?) -> dc_status_t = { userdata in
    guard let t = transport(from: userdata) else { return DC_STATUS_IO }
    t.close()
    return DC_STATUS_SUCCESS
}