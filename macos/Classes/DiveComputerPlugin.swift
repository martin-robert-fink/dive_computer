import FlutterMacOS
import CoreBluetooth
import LibDiveComputer

public class DiveComputerPlugin: NSObject, FlutterPlugin {

    private let methodChannel: FlutterMethodChannel
    private var scanEventSink: FlutterEventSink?
    private var downloadEventSink: FlutterEventSink?

    init(channel: FlutterMethodChannel) {
        self.methodChannel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.example.dive_computer/methods",
            binaryMessenger: registrar.messenger
        )

        let scanChannel = FlutterEventChannel(
            name: "com.example.dive_computer/scan",
            binaryMessenger: registrar.messenger
        )

        let downloadChannel = FlutterEventChannel(
            name: "com.example.dive_computer/download",
            binaryMessenger: registrar.messenger
        )

        let instance = DiveComputerPlugin(channel: methodChannel)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        scanChannel.setStreamHandler(ScanStreamHandler(plugin: instance))
        downloadChannel.setStreamHandler(DownloadStreamHandler(plugin: instance))
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getLibraryVersion":
            result(getLibraryVersion())
        case "getSupportedDescriptors":
            result(getSupportedDescriptors())
        case "stopScan":
            result(nil)
        case "connectToDevice":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Connection not yet implemented", details: nil))
        case "disconnect":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getLibraryVersion() -> String {
        var version = dc_version_t()
        dc_version(&version)
        return "libdivecomputer \(version.major).\(version.minor).\(version.micro)"
    }

    private func getSupportedDescriptors() -> [[String: Any]] {
        var descriptors: [[String: Any]] = []
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS else {
            return descriptors
        }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS {
            guard let desc = descriptor else { continue }
            let vendor = String(cString: dc_descriptor_get_vendor(desc))
            let product = String(cString: dc_descriptor_get_product(desc))
            let family = dc_descriptor_get_type(desc)
            let model = dc_descriptor_get_model(desc)
            let transports = dc_descriptor_get_transports(desc)
            descriptors.append([
                "vendor": vendor,
                "product": product,
                "family": family.rawValue,
                "model": model,
                "transports": transports,
            ])
            dc_descriptor_free(desc)
        }
        dc_iterator_free(iterator)
        return descriptors
    }

    func setScanEventSink(_ sink: FlutterEventSink?) {
        self.scanEventSink = sink
    }

    func setDownloadEventSink(_ sink: FlutterEventSink?) {
        self.downloadEventSink = sink
    }
}

class ScanStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: DiveComputerPlugin?
    init(plugin: DiveComputerPlugin) { self.plugin = plugin }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setScanEventSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setScanEventSink(nil)
        return nil
    }
}

class DownloadStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: DiveComputerPlugin?
    init(plugin: DiveComputerPlugin) { self.plugin = plugin }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setDownloadEventSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.setDownloadEventSink(nil)
        return nil
    }
}