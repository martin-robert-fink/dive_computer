import Foundation
import CoreBluetooth
import LibDiveComputer

/// Represents a BLE dive computer discovered during scanning.
struct DiscoveredDevice {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let vendor: String
    let product: String
    let family: UInt32
    let model: UInt32

    var toMap: [String: Any] {
        return [
            "name": name,
            "address": peripheral.identifier.uuidString,
            "rssi": rssi,
            "vendor": vendor,
            "product": product,
            "family": family,
            "model": model,
        ]
    }
}

/// Callback protocol for BLE scan events.
protocol BLEManagerDelegate: AnyObject {
    func bleManager(_ manager: BLEManager, didDiscoverDevice device: DiscoveredDevice)
    func bleManager(_ manager: BLEManager, didUpdateState state: CBManagerState)
    func bleManager(_ manager: BLEManager, didFailWithError message: String)
}

/// Manages CoreBluetooth scanning, connection, and filtering of discovered
/// peripherals against libdivecomputer's known device descriptors.
class BLEManager: NSObject {

    weak var delegate: BLEManagerDelegate?

    /// Dedicated serial queue for all CoreBluetooth operations.
    /// Keeps BLE callbacks off the main queue so they are never delayed
    /// by Flutter UI updates — critical for maintaining the timing that
    /// dive computers (especially Shearwater) require during downloads.
    let bleQueue = DispatchQueue(label: "com.divecomputer.ble", qos: .userInitiated)

    private var centralManager: CBCentralManager?
    private var isScanning = false

    /// Cache of libdivecomputer descriptors that support BLE transport.
    private var bleDescriptors: [(descriptor: OpaquePointer, vendor: String, product: String, family: UInt32, model: UInt32)] = []

    /// Track already-reported peripherals (by UUID) to avoid duplicates.
    private var discoveredPeripheralIDs: Set<UUID> = []

    // Connection state
    private var connectCompletion: ((Bool, String?) -> Void)?
    private var disconnectCompletion: (() -> Void)?
    private(set) var connectedPeripheral: CBPeripheral?

    override init() {
        super.init()
        loadBLEDescriptors()
    }

    deinit {
        stopScan()
        freeBLEDescriptors()
    }

    // MARK: - Public API: Scanning

    func startScan() {
        discoveredPeripheralIDs.removeAll()

        if centralManager == nil {
            // Create on the dedicated BLE queue — all delegate callbacks
            // will be delivered on this queue, not the main queue.
            centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        } else if centralManager?.state == .poweredOn {
            beginScanning()
        } else {
            let state = centralManager?.state ?? .unknown
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.bleManager(self, didUpdateState: state)
            }
        }
    }

    func stopScan() {
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
        }
    }

    // MARK: - Public API: Connection

    /// Connect to a discovered BLE peripheral.
    /// Completion is called with (success, errorMessage).
    func connect(peripheral: CBPeripheral, completion: @escaping (Bool, String?) -> Void) {
        // Stop scanning before connecting
        stopScan()

        guard let cm = centralManager, cm.state == .poweredOn else {
            completion(false, "Bluetooth is not powered on")
            return
        }

        self.connectCompletion = completion
        self.connectedPeripheral = peripheral
        cm.connect(peripheral, options: nil)
        NSLog("[BLEManager] Connecting to \(peripheral.identifier)...")
    }

    /// Disconnect from the currently connected peripheral.
    func disconnect(completion: (() -> Void)? = nil) {
        guard let peripheral = connectedPeripheral, let cm = centralManager else {
            completion?()
            return
        }
        self.disconnectCompletion = completion
        cm.cancelPeripheralConnection(peripheral)
        NSLog("[BLEManager] Disconnecting from \(peripheral.identifier)...")
    }

    /// Find a libdivecomputer descriptor matching the given vendor and product.
    /// Returns a freshly iterated descriptor that the caller must free.
    func findDescriptor(vendor: String, product: String) -> OpaquePointer? {
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS,
              let iter = iterator else {
            return nil
        }

        var descriptor: OpaquePointer?
        while dc_iterator_next(iter, &descriptor) == DC_STATUS_SUCCESS {
            guard let desc = descriptor else { continue }
            let v = String(cString: dc_descriptor_get_vendor(desc))
            let p = String(cString: dc_descriptor_get_product(desc))
            if v == vendor && p == product {
                dc_iterator_free(iter)
                return desc  // Caller owns this — must free when done
            }
            dc_descriptor_free(desc)
        }
        dc_iterator_free(iter)
        return nil
    }

    // MARK: - Descriptor Loading

    private func loadBLEDescriptors() {
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS,
              let iter = iterator else {
            return
        }

        var descriptor: OpaquePointer?
        while dc_iterator_next(iter, &descriptor) == DC_STATUS_SUCCESS {
            guard let desc = descriptor else { continue }
            let transports = dc_descriptor_get_transports(desc)
            if (transports & UInt32(DC_TRANSPORT_BLE.rawValue)) != 0 {
                let vendor = String(cString: dc_descriptor_get_vendor(desc))
                let product = String(cString: dc_descriptor_get_product(desc))
                let family = dc_descriptor_get_type(desc).rawValue
                let model = dc_descriptor_get_model(desc)
                bleDescriptors.append((
                    descriptor: desc,
                    vendor: vendor,
                    product: product,
                    family: family,
                    model: model
                ))
            } else {
                dc_descriptor_free(desc)
            }
        }
        dc_iterator_free(iter)
        NSLog("[BLEManager] Loaded \(bleDescriptors.count) BLE-capable descriptors")
    }

    private func freeBLEDescriptors() {
        for entry in bleDescriptors {
            dc_descriptor_free(entry.descriptor)
        }
        bleDescriptors.removeAll()
    }

    // MARK: - Scanning

    private func beginScanning() {
        guard !isScanning else { return }
        isScanning = true
        centralManager?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        NSLog("[BLEManager] BLE scan started")
    }

    private func matchDescriptor(name: String) -> (vendor: String, product: String, family: UInt32, model: UInt32)? {
        for entry in bleDescriptors {
            let matched = name.withCString { cName in
                dc_descriptor_filter(entry.descriptor, DC_TRANSPORT_BLE, cName)
            }
            if matched != 0 {
                return (entry.vendor, entry.product, entry.family, entry.model)
            }
        }
        return nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    // NOTE: All delegate methods below are called on bleQueue, not the main queue.
    // Calls to the delegate (which touch Flutter event sinks) must be
    // dispatched to the main queue.

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.bleManager(self, didUpdateState: state)
        }

        switch state {
        case .poweredOn:
            NSLog("[BLEManager] Bluetooth powered on")
            beginScanning()
        case .poweredOff:
            NSLog("[BLEManager] Bluetooth powered off")
            isScanning = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.bleManager(self, didFailWithError: "Bluetooth is powered off")
            }
        case .unauthorized:
            NSLog("[BLEManager] Bluetooth unauthorized")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.bleManager(self, didFailWithError: "Bluetooth permission denied. Check Settings > Privacy & Security > Bluetooth.")
            }
        case .unsupported:
            NSLog("[BLEManager] Bluetooth unsupported")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.bleManager(self, didFailWithError: "Bluetooth LE is not supported on this device")
            }
        default:
            NSLog("[BLEManager] Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !discoveredPeripheralIDs.contains(peripheral.identifier) else { return }

        let name: String
        if let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !advName.isEmpty {
            name = advName
        } else if let peripheralName = peripheral.name, !peripheralName.isEmpty {
            name = peripheralName
        } else {
            return
        }

        guard let match = matchDescriptor(name: name) else { return }

        discoveredPeripheralIDs.insert(peripheral.identifier)

        let device = DiscoveredDevice(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            vendor: match.vendor,
            product: match.product,
            family: match.family,
            model: match.model
        )

        NSLog("[BLEManager] Discovered dive computer: \(match.vendor) \(match.product) (\(name)) RSSI: \(RSSI)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.bleManager(self, didDiscoverDevice: device)
        }
    }

    // MARK: Connection callbacks

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[BLEManager] Connected to \(peripheral.identifier)")
        let completion = connectCompletion
        connectCompletion = nil
        completion?(true, nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "Unknown connection error"
        NSLog("[BLEManager] Failed to connect: \(msg)")
        connectedPeripheral = nil
        let completion = connectCompletion
        connectCompletion = nil
        completion?(false, msg)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        NSLog("[BLEManager] Disconnected from \(peripheral.identifier)" +
              (error != nil ? " error: \(error!)" : ""))
        connectedPeripheral = nil
        let completion = disconnectCompletion
        disconnectCompletion = nil
        completion?()
    }
}