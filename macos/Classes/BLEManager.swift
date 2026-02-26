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

/// Manages CoreBluetooth scanning and filters discovered peripherals
/// against libdivecomputer's known device descriptors.
class BLEManager: NSObject {

    weak var delegate: BLEManagerDelegate?

    private var centralManager: CBCentralManager?
    private var isScanning = false

    /// Cache of libdivecomputer descriptors that support BLE transport.
    /// Loaded once and reused across scans.
    private var bleDescriptors: [(descriptor: OpaquePointer, vendor: String, product: String, family: UInt32, model: UInt32)] = []

    /// Track already-reported peripherals (by UUID) to avoid duplicates
    /// within a single scan session.
    private var discoveredPeripheralIDs: Set<UUID> = []

    override init() {
        super.init()
        loadBLEDescriptors()
    }

    deinit {
        stopScan()
        freeBLEDescriptors()
    }

    // MARK: - Public API

    func startScan() {
        discoveredPeripheralIDs.removeAll()

        if centralManager == nil {
            // Creating CBCentralManager triggers a delegate callback with the
            // current state. If the state is .poweredOn, we start scanning
            // from the delegate method.
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else if centralManager?.state == .poweredOn {
            beginScanning()
        } else {
            delegate?.bleManager(self, didUpdateState: centralManager?.state ?? .unknown)
        }
    }

    func stopScan() {
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
        }
    }

    // MARK: - Descriptor Loading

    /// Load all libdivecomputer descriptors that support BLE transport.
    /// We keep the OpaquePointers alive so we can call dc_descriptor_filter
    /// on each discovered peripheral.
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
            // Only keep descriptors that support BLE (bit 5 = 0x20)
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
        // Scan for all BLE peripherals — we filter by name against
        // libdivecomputer descriptors rather than by service UUID,
        // because dive computers advertise with varying service UUIDs.
        centralManager?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        NSLog("[BLEManager] BLE scan started")
    }

    /// Check a discovered peripheral's name against all cached BLE
    /// descriptors using libdivecomputer's dc_descriptor_filter.
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

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.bleManager(self, didUpdateState: central.state)

        switch central.state {
        case .poweredOn:
            NSLog("[BLEManager] Bluetooth powered on")
            // If a scan was requested before BT was ready, start now
            beginScanning()
        case .poweredOff:
            NSLog("[BLEManager] Bluetooth powered off")
            isScanning = false
            delegate?.bleManager(self, didFailWithError: "Bluetooth is powered off")
        case .unauthorized:
            NSLog("[BLEManager] Bluetooth unauthorized")
            delegate?.bleManager(self, didFailWithError: "Bluetooth permission denied. Check System Settings > Privacy & Security > Bluetooth.")
        case .unsupported:
            NSLog("[BLEManager] Bluetooth unsupported")
            delegate?.bleManager(self, didFailWithError: "Bluetooth LE is not supported on this device")
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
        // Skip peripherals we've already reported in this scan session
        guard !discoveredPeripheralIDs.contains(peripheral.identifier) else { return }

        // Get the advertised name — prefer advertisementData over peripheral.name
        // since peripheral.name can be cached from previous connections
        let name: String
        if let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !advName.isEmpty {
            name = advName
        } else if let peripheralName = peripheral.name, !peripheralName.isEmpty {
            name = peripheralName
        } else {
            return // Skip unnamed peripherals — can't match against descriptors
        }

        // Filter against libdivecomputer descriptors
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
        delegate?.bleManager(self, didDiscoverDevice: device)
    }
}