import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dive_computer/dive_computer.dart';

void main() {
  runApp(const DiveComputerExampleApp());
}

class DiveComputerExampleApp extends StatelessWidget {
  const DiveComputerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dive Computer Plugin Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _plugin = DiveComputerPlugin.instance;

  String _libraryVersion = 'Loading...';
  String _statusMessage = '';

  // BLE scan state
  bool _isScanning = false;
  final List<DcDeviceInfo> _discoveredDevices = [];
  StreamSubscription<Map<String, dynamic>>? _scanSubscription;

  // Connection state
  bool _isConnecting = false;
  bool _isConnected = false;
  DcDeviceInfo? _connectedDevice;

  // Download state
  bool _isDownloading = false;
  double _downloadProgress = 0;
  int _downloadCurrent = 0;
  int _downloadMaximum = 0;
  final List<DcDive> _dives = [];
  StreamSubscription<Map<String, dynamic>>? _downloadSubscription;
  int? _devInfoSerial;
  int? _devInfoFirmware;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _stopScan();
    _downloadSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final version = await _plugin.getLibraryVersion();
      setState(() => _libraryVersion = version);
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    }
  }

  // MARK: - Scanning

  void _startScan() {
    setState(() {
      _isScanning = true;
      _discoveredDevices.clear();
    });

    _scanSubscription = _plugin.scanForDevices().listen(
      (event) {
        final device = DcDeviceInfo.fromMap(event);
        setState(() {
          final idx = _discoveredDevices.indexWhere(
            (d) => d.address == device.address,
          );
          if (idx >= 0) {
            _discoveredDevices[idx] = device;
          } else {
            _discoveredDevices.add(device);
          }
        });
      },
      onError: (error) {
        setState(() {
          _isScanning = false;
          _statusMessage = 'Scan error: $error';
        });
      },
      onDone: () => setState(() => _isScanning = false),
    );
  }

  Future<void> _stopScan() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await _plugin.stopScan();
    } catch (_) {}
    if (mounted) setState(() => _isScanning = false);
  }

  // MARK: - Connection

  Future<void> _connectToDevice(DcDeviceInfo device) async {
    await _stopScan();

    setState(() {
      _isConnecting = true;
      _statusMessage = 'Connecting to ${device.name}...';
    });

    try {
      final success = await _plugin.connectToDevice(
        address: device.address,
        vendor: device.vendor,
        product: device.product,
      );

      setState(() {
        _isConnecting = false;
        if (success) {
          _isConnected = true;
          _connectedDevice = device;
          _statusMessage = 'Connected to ${device.vendor} ${device.product}!';
        } else {
          _statusMessage = 'Connection failed';
        }
      });
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _statusMessage = 'Connection error: $e';
      });
    }
  }

  Future<void> _disconnect() async {
    _downloadSubscription?.cancel();
    _downloadSubscription = null;
    setState(() => _statusMessage = 'Disconnecting...');

    try {
      await _plugin.disconnect();
    } catch (_) {}

    setState(() {
      _isConnected = false;
      _isDownloading = false;
      _connectedDevice = null;
      _dives.clear();
      _downloadProgress = 0;
      _downloadCurrent = 0;
      _downloadMaximum = 0;
      _devInfoSerial = null;
      _devInfoFirmware = null;
      _statusMessage = 'Disconnected';
    });
  }

  // MARK: - Download

  void _cancelDownload() {
    _downloadSubscription?.cancel();
    _downloadSubscription = null;
    setState(() {
      _isDownloading = false;
      _statusMessage = 'Download cancelled — ${_dives.length} dives retrieved';
    });
  }

  void _startDownload() {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadCurrent = 0;
      _downloadMaximum = 0;
      _dives.clear();
      _devInfoSerial = null;
      _devInfoFirmware = null;
      _statusMessage = 'Downloading dives...';
    });

    _downloadSubscription = _plugin.downloadDives().listen(
      (event) {
        final type = event['type'] as String?;

        switch (type) {
          case 'progress':
            final current = event['current'] as int? ?? 0;
            final maximum = event['maximum'] as int? ?? 1;
            setState(() {
              _downloadCurrent = current;
              _downloadMaximum = maximum;
              _downloadProgress = maximum > 0 ? current / maximum : 0;
            });

          case 'devinfo':
            setState(() {
              _devInfoSerial = event['serial'] as int?;
              _devInfoFirmware = event['firmware'] as int?;
            });

          case 'dive':
            final dive = DcDive.fromMap(event);
            setState(() {
              _dives.add(dive);
              _statusMessage = 'Downloaded ${_dives.length} dives...';
            });

          case 'complete':
            final total = event['totalDives'] as int? ?? _dives.length;
            setState(() {
              _isDownloading = false;
              _downloadProgress = 1.0;
              _statusMessage = 'Download complete: $total dives';
            });
        }
      },
      onError: (error) {
        setState(() {
          _isDownloading = false;
          _statusMessage = 'Download error: $error';
        });
      },
      onDone: () {
        setState(() => _isDownloading = false);
      },
    );
  }

  // MARK: - Build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dive Computer Plugin Test')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Library status
            Card(
              child: ListTile(
                leading: Icon(
                  _libraryVersion.contains('libdivecomputer')
                      ? Icons.check_circle
                      : Icons.error,
                  color: _libraryVersion.contains('libdivecomputer')
                      ? Colors.green
                      : Colors.red,
                ),
                title: const Text('Library Status'),
                subtitle: Text(_libraryVersion),
              ),
            ),
            const SizedBox(height: 8),

            // Status message
            if (_statusMessage.isNotEmpty)
              Card(
                color: _isConnected ? Colors.green.shade50 : null,
                child: ListTile(
                  leading: Icon(
                    _isConnected
                        ? Icons.bluetooth_connected
                        : _isConnecting
                        ? Icons.bluetooth_searching
                        : Icons.info_outline,
                    color: _isConnected ? Colors.green : null,
                  ),
                  title: Text(_isConnected ? 'Connected' : 'Status'),
                  subtitle: Text(_statusMessage),
                  trailing: _isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
              ),
            const SizedBox(height: 16),

            // Connected device section
            if (_isConnected && _connectedDevice != null) ...[
              // Device info card with disconnect
              Card(
                color: Colors.green.shade50,
                child: ListTile(
                  leading: const Icon(
                    Icons.bluetooth_connected,
                    color: Colors.green,
                    size: 32,
                  ),
                  title: Text(
                    '${_connectedDevice!.vendor} ${_connectedDevice!.product}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    _connectedDevice!.address +
                        (_devInfoSerial != null
                            ? '\nS/N: $_devInfoSerial  FW: $_devInfoFirmware'
                            : ''),
                  ),
                  isThreeLine: _devInfoSerial != null,
                  trailing: FilledButton.tonal(
                    onPressed: _isDownloading ? null : _disconnect,
                    child: const Text('Disconnect'),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Download button + progress
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _isDownloading ? null : _startDownload,
                    icon: Icon(
                      _isDownloading ? Icons.hourglass_top : Icons.download,
                    ),
                    label: Text(
                      _isDownloading
                          ? 'Downloading...'
                          : _dives.isEmpty
                          ? 'Download Dives'
                          : 'Re-download',
                    ),
                  ),
                  if (_isDownloading) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _cancelDownload,
                      icon: const Icon(Icons.cancel),
                      label: const Text('Cancel'),
                    ),
                  ],
                  const SizedBox(width: 16),
                  if (_isDownloading || _downloadProgress > 0)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            value: _isDownloading ? _downloadProgress : 1.0,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isDownloading
                                ? '${(_downloadProgress * 100).toInt()}%  •  ${_dives.length} dives  •  ${_formatBytes(_downloadCurrent)} / ${_formatBytes(_downloadMaximum)}'
                                : '${_dives.length} dives downloaded',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Dive list header
              if (_dives.isNotEmpty)
                Text(
                  'Dives (${_dives.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              const SizedBox(height: 4),
            ],

            // BLE Scan section (when not connected)
            if (!_isConnected) ...[
              Row(
                children: [
                  Text(
                    'BLE Scan',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (_isScanning)
                    const Padding(
                      padding: EdgeInsets.only(right: 8.0),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _isConnecting
                        ? null
                        : (_isScanning ? _stopScan : _startScan),
                    icon: Icon(
                      _isScanning ? Icons.stop : Icons.bluetooth_searching,
                    ),
                    label: Text(_isScanning ? 'Stop' : 'Scan'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_discoveredDevices.isEmpty && _isScanning)
                const Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.bluetooth_searching,
                      color: Colors.blue,
                    ),
                    title: Text('Scanning for dive computers...'),
                    subtitle: Text(
                      'Make sure your dive computer is in Bluetooth pairing mode',
                    ),
                  ),
                ),
              if (_discoveredDevices.isEmpty && !_isScanning && !_isConnecting)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.bluetooth_disabled, color: Colors.grey),
                    title: Text('No devices found'),
                    subtitle: Text(
                      'Press Scan to search for BLE dive computers',
                    ),
                  ),
                ),
            ],

            // Scrollable content area
            Expanded(
              child: ListView(
                children: [
                  // Discovered BLE devices (when scanning)
                  if (!_isConnected)
                    ..._discoveredDevices.map(
                      (device) => Card(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        child: ListTile(
                          leading: const Icon(
                            Icons.bluetooth_connected,
                            color: Colors.blue,
                          ),
                          title: Text(device.name),
                          subtitle: Text(
                            '${device.vendor} ${device.product}\n'
                            'RSSI: ${device.rssi} dBm  •  ${device.address}',
                          ),
                          isThreeLine: true,
                          trailing: FilledButton(
                            onPressed: _isConnecting
                                ? null
                                : () => _connectToDevice(device),
                            child: _isConnecting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Connect'),
                          ),
                        ),
                      ),
                    ),

                  // Dive list (when connected and downloaded)
                  if (_isConnected)
                    ..._dives.map((dive) => _buildDiveCard(dive)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _buildDiveCard(DcDive dive) {
    final dateStr = dive.dateTime != null
        ? '${dive.dateTime!.year}-${dive.dateTime!.month.toString().padLeft(2, '0')}-'
              '${dive.dateTime!.day.toString().padLeft(2, '0')}  '
              '${dive.dateTime!.hour.toString().padLeft(2, '0')}:'
              '${dive.dateTime!.minute.toString().padLeft(2, '0')}'
        : 'Unknown date';

    final details = <String>[
      dive.depthStr,
      dive.timeStr,
      if (dive.tempStr.isNotEmpty) dive.tempStr,
      if (dive.diveMode != null) dive.diveMode!,
      if (dive.gasStr.isNotEmpty) dive.gasStr,
    ];

    final sampleCount = dive.samples?.length ?? 0;

    return Card(
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade100,
          child: Text(
            '${dive.number}',
            style: TextStyle(
              color: Colors.blue.shade800,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(dateStr),
        subtitle: Text(details.join('  •  ')),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Max Depth', dive.depthStr),
                if (dive.avgDepth != null)
                  _detailRow(
                    'Avg Depth',
                    '${dive.avgDepth!.toStringAsFixed(1)}m',
                  ),
                _detailRow('Duration', dive.timeStr),
                if (dive.diveMode != null) _detailRow('Mode', dive.diveMode!),
                if (dive.minTemperature != null)
                  _detailRow(
                    'Min Temp',
                    '${dive.minTemperature!.toStringAsFixed(1)}°C',
                  ),
                if (dive.maxTemperature != null)
                  _detailRow(
                    'Max Temp',
                    '${dive.maxTemperature!.toStringAsFixed(1)}°C',
                  ),
                if (dive.gasMixes != null && dive.gasMixes!.isNotEmpty)
                  _detailRow('Gas', dive.gasStr),
                if (dive.tanks != null && dive.tanks!.isNotEmpty)
                  ...dive.tanks!.asMap().entries.map(
                    (e) => _detailRow('Tank ${e.key + 1}', e.value.toString()),
                  ),
                _detailRow('Samples', '$sampleCount points'),
                if (dive.fingerprint != null)
                  _detailRow(
                    'Fingerprint',
                    '${dive.fingerprint!.substring(0, dive.fingerprint!.length > 16 ? 16 : dive.fingerprint!.length)}...',
                  ),
                if (dive.error != null)
                  _detailRow('Error', dive.error!, isError: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: isError ? Colors.red : null),
            ),
          ),
        ],
      ),
    );
  }
}
