import Foundation
import LibDiveComputer

/// Callback type for streaming download events to Flutter.
typealias DownloadEventCallback = ([String: Any]) -> Void

/// Manages the dive download process using libdivecomputer's
/// dc_device_foreach and dc_parser APIs. Runs entirely on a
/// background DispatchQueue to avoid blocking the main thread.
class DiveDownloader {

    private let device: OpaquePointer     // dc_device_t*
    private let onEvent: DownloadEventCallback

    fileprivate var diveCount = 0
    fileprivate var isCancelled = false

    init(device: OpaquePointer, onEvent: @escaping DownloadEventCallback) {
        self.device = device
        self.onEvent = onEvent
    }

    /// Start the download on a background thread.
    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performDownload()
        }
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Download

    private func performDownload() {
        NSLog("[DiveDownloader] Starting dive download")

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Register for progress and devinfo events
        dc_device_set_events(device,
                             UInt32(DC_EVENT_PROGRESS.rawValue | DC_EVENT_DEVINFO.rawValue),
                             deviceEventCallback,
                             selfPtr)

        // Set cancel callback
        dc_device_set_cancel(device, deviceCancelCallback, selfPtr)

        // Enumerate dives
        let status = dc_device_foreach(device, diveCallback, selfPtr)

        let statusName: String
        switch status {
        case DC_STATUS_SUCCESS: statusName = "success"
        case DC_STATUS_DONE:    statusName = "done"
        default:                statusName = "error(\(status.rawValue))"
        }

        NSLog("[DiveDownloader] Download finished: \(statusName), \(diveCount) dives")

        sendEvent([
            "type": "complete",
            "totalDives": diveCount,
            "status": statusName,
        ])
    }

    // MARK: - Event Sending (thread-safe to main queue)

    fileprivate func sendEvent(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent(event)
        }
    }

    // MARK: - Dive Parsing

    fileprivate func processDive(data: UnsafePointer<UInt8>, size: UInt32,
                                  fingerprint: UnsafePointer<UInt8>?, fpSize: UInt32) -> Bool {
        diveCount += 1

        var parser: OpaquePointer?
        let status = dc_parser_new(&parser, device, data, Int(size))

        guard status == DC_STATUS_SUCCESS, let parser = parser else {
            NSLog("[DiveDownloader] Failed to create parser for dive \(diveCount): \(status.rawValue)")
            sendEvent([
                "type": "dive",
                "number": diveCount,
                "error": "Parser creation failed (\(status.rawValue))",
            ])
            return true // Continue to next dive
        }

        defer { dc_parser_destroy(parser) }

        var diveEvent: [String: Any] = [
            "type": "dive",
            "number": diveCount,
        ]

        // DateTime
        var datetime = dc_datetime_t()
        if dc_parser_get_datetime(parser, &datetime) == DC_STATUS_SUCCESS {
            let dateStr = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                                 datetime.year, datetime.month, datetime.day,
                                 datetime.hour, datetime.minute, datetime.second)
            diveEvent["dateTime"] = dateStr
        }

        // Dive time (seconds)
        var divetime: UInt32 = 0
        if dc_parser_get_field(parser, DC_FIELD_DIVETIME, 0, &divetime) == DC_STATUS_SUCCESS {
            diveEvent["diveTime"] = Int(divetime)
        }

        // Max depth (meters)
        var maxdepth: Double = 0
        if dc_parser_get_field(parser, DC_FIELD_MAXDEPTH, 0, &maxdepth) == DC_STATUS_SUCCESS {
            diveEvent["maxDepth"] = maxdepth
        }

        // Avg depth (meters)
        var avgdepth: Double = 0
        if dc_parser_get_field(parser, DC_FIELD_AVGDEPTH, 0, &avgdepth) == DC_STATUS_SUCCESS {
            diveEvent["avgDepth"] = avgdepth
        }

        // Temperature (minimum)
        var minTemp: Double = 0
        if dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MINIMUM, 0, &minTemp) == DC_STATUS_SUCCESS {
            diveEvent["minTemperature"] = minTemp
        }

        // Temperature (maximum)
        var maxTemp: Double = 0
        if dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MAXIMUM, 0, &maxTemp) == DC_STATUS_SUCCESS {
            diveEvent["maxTemperature"] = maxTemp
        }

        // Surface temperature
        var surfTemp: Double = 0
        if dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_SURFACE, 0, &surfTemp) == DC_STATUS_SUCCESS {
            diveEvent["surfaceTemperature"] = surfTemp
        }

        // Dive mode
        var divemode = DC_DIVEMODE_OC
        if dc_parser_get_field(parser, DC_FIELD_DIVEMODE, 0, &divemode) == DC_STATUS_SUCCESS {
            let modeStr: String
            switch divemode {
            case DC_DIVEMODE_FREEDIVE: modeStr = "freedive"
            case DC_DIVEMODE_GAUGE:    modeStr = "gauge"
            case DC_DIVEMODE_OC:       modeStr = "OC"
            case DC_DIVEMODE_CCR:      modeStr = "CCR"
            case DC_DIVEMODE_SCR:      modeStr = "SCR"
            default:                   modeStr = "unknown"
            }
            diveEvent["diveMode"] = modeStr
        }

        // Atmospheric pressure
        var atmospheric: Double = 0
        if dc_parser_get_field(parser, DC_FIELD_ATMOSPHERIC, 0, &atmospheric) == DC_STATUS_SUCCESS {
            diveEvent["atmospheric"] = atmospheric
        }

        // Gas mixes
        var gasmixCount: UInt32 = 0
        if dc_parser_get_field(parser, DC_FIELD_GASMIX_COUNT, 0, &gasmixCount) == DC_STATUS_SUCCESS,
           gasmixCount > 0 {
            var mixes: [[String: Any]] = []
            for i in 0..<gasmixCount {
                var gasmix = dc_gasmix_t()
                if dc_parser_get_field(parser, DC_FIELD_GASMIX, i, &gasmix) == DC_STATUS_SUCCESS {
                    mixes.append([
                        "oxygen": gasmix.oxygen,
                        "helium": gasmix.helium,
                        "nitrogen": gasmix.nitrogen,
                    ])
                }
            }
            if !mixes.isEmpty {
                diveEvent["gasMixes"] = mixes
            }
        }

        // Tank info
        var tankCount: UInt32 = 0
        if dc_parser_get_field(parser, DC_FIELD_TANK_COUNT, 0, &tankCount) == DC_STATUS_SUCCESS,
           tankCount > 0 {
            var tanks: [[String: Any]] = []
            for i in 0..<tankCount {
                var tank = dc_tank_t()
                if dc_parser_get_field(parser, DC_FIELD_TANK, i, &tank) == DC_STATUS_SUCCESS {
                    var tankMap: [String: Any] = [
                        "beginPressure": tank.beginpressure,
                        "endPressure": tank.endpressure,
                    ]
                    if tank.volume > 0 {
                        tankMap["volume"] = tank.volume
                    }
                    if tank.workpressure > 0 {
                        tankMap["workPressure"] = tank.workpressure
                    }
                    if tank.gasmix != DC_GASMIX_UNKNOWN {
                        tankMap["gasmix"] = Int(tank.gasmix)
                    }
                    tanks.append(tankMap)
                }
            }
            if !tanks.isEmpty {
                diveEvent["tanks"] = tanks
            }
        }

        // Depth profile samples
        let sampleCollector = SampleCollector()
        let samplePtr = Unmanaged.passUnretained(sampleCollector).toOpaque()
        dc_parser_samples_foreach(parser, sampleCallback, samplePtr)
        sampleCollector.flush() // Flush the last sample (no trailing TIME event)

        if !sampleCollector.samples.isEmpty {
            diveEvent["samples"] = sampleCollector.samples
        }

        // Fingerprint (for incremental downloads later)
        if let fp = fingerprint, fpSize > 0 {
            let fpData = Data(bytes: fp, count: Int(fpSize))
            diveEvent["fingerprint"] = fpData.map { String(format: "%02x", $0) }.joined()
        }

        NSLog("[DiveDownloader] Dive #\(diveCount): depth=\(diveEvent["maxDepth"] ?? "?")m, " +
              "time=\(diveEvent["diveTime"] ?? "?")s, samples=\(sampleCollector.samples.count)")

        sendEvent(diveEvent)
        return true // Continue to next dive
    }
}

// MARK: - Sample Collector

/// Collects depth profile samples from dc_parser_samples_foreach.
fileprivate class SampleCollector {
    var samples: [[String: Any]] = []
    var currentSample: [String: Any] = [:]

    func flush() {
        if !currentSample.isEmpty {
            samples.append(currentSample)
            currentSample = [:]
        }
    }
}

// MARK: - C Callbacks

/// Device event callback (progress, devinfo).
private let deviceEventCallback: @convention(c)
    (OpaquePointer?, dc_event_type_t, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void =
{ _, event, data, userdata in
    guard let userdata = userdata, let data = data else { return }
    let downloader = Unmanaged<DiveDownloader>.fromOpaque(userdata).takeUnretainedValue()

    switch event {
    case DC_EVENT_PROGRESS:
        let progress = data.assumingMemoryBound(to: dc_event_progress_t.self).pointee
        downloader.sendEvent([
            "type": "progress",
            "current": Int(progress.current),
            "maximum": Int(progress.maximum),
        ])

    case DC_EVENT_DEVINFO:
        let devinfo = data.assumingMemoryBound(to: dc_event_devinfo_t.self).pointee
        NSLog("[DiveDownloader] DevInfo: model=\(devinfo.model) fw=\(devinfo.firmware) serial=\(devinfo.serial)")
        downloader.sendEvent([
            "type": "devinfo",
            "model": Int(devinfo.model),
            "firmware": Int(devinfo.firmware),
            "serial": Int(devinfo.serial),
        ])

    default:
        break
    }
}

/// Cancel callback — checks if download was cancelled.
private let deviceCancelCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userdata in
    guard let userdata = userdata else { return 0 }
    let downloader = Unmanaged<DiveDownloader>.fromOpaque(userdata).takeUnretainedValue()
    return downloader.isCancelled ? 1 : 0
}

/// Dive callback — called for each dive found on the device.
private let diveCallback: @convention(c)
    (UnsafePointer<UInt8>?, UInt32, UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Int32 =
{ data, size, fingerprint, fpSize, userdata in
    guard let userdata = userdata, let data = data, size > 0 else { return 1 }
    let downloader = Unmanaged<DiveDownloader>.fromOpaque(userdata).takeUnretainedValue()

    let shouldContinue = downloader.processDive(data: data, size: size,
                                                 fingerprint: fingerprint, fpSize: fpSize)
    return shouldContinue ? 1 : 0
}

/// Sample callback — called for each sample point in a dive profile.
private let sampleCallback: @convention(c)
    (dc_sample_type_t, UnsafePointer<dc_sample_value_t>?, UnsafeMutableRawPointer?) -> Void =
{ type, value, userdata in
    guard let userdata = userdata, let value = value else { return }
    let collector = Unmanaged<SampleCollector>.fromOpaque(userdata).takeUnretainedValue()

    switch type {
    case DC_SAMPLE_TIME:
        // New sample point — flush previous
        collector.flush()
        collector.currentSample["time"] = Int(value.pointee.time) // milliseconds

    case DC_SAMPLE_DEPTH:
        collector.currentSample["depth"] = value.pointee.depth

    case DC_SAMPLE_TEMPERATURE:
        collector.currentSample["temperature"] = value.pointee.temperature

    case DC_SAMPLE_PRESSURE:
        collector.currentSample["pressure"] = value.pointee.pressure.value
        collector.currentSample["tank"] = Int(value.pointee.pressure.tank)

    case DC_SAMPLE_SETPOINT:
        collector.currentSample["setpoint"] = value.pointee.setpoint

    case DC_SAMPLE_PPO2:
        collector.currentSample["ppo2"] = value.pointee.ppo2.value

    case DC_SAMPLE_CNS:
        collector.currentSample["cns"] = value.pointee.cns

    case DC_SAMPLE_DECO:
        collector.currentSample["decoType"] = Int(value.pointee.deco.type)
        collector.currentSample["decoDepth"] = value.pointee.deco.depth
        collector.currentSample["decoTime"] = Int(value.pointee.deco.time)
        collector.currentSample["tts"] = Int(value.pointee.deco.tts)

    case DC_SAMPLE_HEARTBEAT:
        collector.currentSample["heartbeat"] = Int(value.pointee.heartbeat)

    case DC_SAMPLE_GASMIX:
        collector.currentSample["gasmix"] = Int(value.pointee.gasmix)

    default:
        break
    }
}