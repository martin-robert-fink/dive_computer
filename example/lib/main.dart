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
      title: 'Dive Computer',
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
  bool _forceDownload = false;
  double _downloadProgress = 0;
  int? _totalDiveCount;
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
      _totalDiveCount = null;
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

  Future<void> _resetFingerprint() async {
    await _plugin.resetFingerprint();
    setState(() {
      _statusMessage = 'Fingerprint reset — next download will fetch all dives';
    });
  }

  void _startDownload() {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _totalDiveCount = null;
      _dives.clear();
      _devInfoSerial = null;
      _devInfoFirmware = null;
      _statusMessage = 'Downloading dives...';
    });

    _downloadSubscription = _plugin
        .downloadDives(forceDownload: _forceDownload)
        .listen(
          (event) {
            final type = event['type'] as String?;

            switch (type) {
              case 'progress':
                final current = event['current'] as int? ?? 0;
                final maximum = event['maximum'] as int? ?? 1;
                setState(() {
                  _downloadProgress = maximum > 0 ? current / maximum : 0;
                });

              case 'devinfo':
                setState(() {
                  _devInfoSerial = event['serial'] as int?;
                  _devInfoFirmware = event['firmware'] as int?;
                });

              case 'totalDives':
                setState(() {
                  _totalDiveCount = event['totalDives'] as int?;
                  if (_totalDiveCount != null) {
                    _statusMessage =
                        'Found $_totalDiveCount dives, downloading...';
                  }
                });

              case 'dive':
                final dive = DcDive.fromMap(event);
                final total = event['totalDives'] as int?;
                setState(() {
                  _dives.add(dive);
                  if (total != null) _totalDiveCount = total;
                  _statusMessage = _totalDiveCount != null
                      ? 'Downloaded ${_dives.length} of $_totalDiveCount dives...'
                      : 'Downloaded ${_dives.length} dives...';
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
      appBar: AppBar(title: const Text('Dive Computer')),
      body: SafeArea(
        child: _isConnected ? _buildConnectedView() : _buildScanView(),
      ),
    );
  }

  // MARK: - Scan View

  Widget _buildScanView() {
    return Column(
      children: [
        // Fixed header area
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLibraryStatusCard(),
              if (_statusMessage.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildStatusCard(),
              ],
              const SizedBox(height: 16),
              _buildScanHeader(),
              const SizedBox(height: 8),
            ],
          ),
        ),

        // Scrollable device list
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              if (_discoveredDevices.isEmpty && _isScanning)
                const Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.bluetooth_searching,
                      color: Colors.blue,
                    ),
                    title: Text('Scanning for dive computers...'),
                    subtitle: Text(
                      'Make sure your dive computer is in '
                      'Bluetooth pairing mode',
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
              ..._discoveredDevices.map(_buildDeviceCard),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScanHeader() {
    return Row(
      children: [
        Text('BLE Scan', style: Theme.of(context).textTheme.titleMedium),
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
          icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(_isScanning ? 'Stop' : 'Scan'),
        ),
      ],
    );
  }

  Widget _buildDeviceCard(DcDeviceInfo device) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth_connected, color: Colors.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${device.vendor} ${device.product}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        'RSSI: ${device.rssi} dBm',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
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
          ],
        ),
      ),
    );
  }

  // MARK: - Connected View

  Widget _buildConnectedView() {
    return Column(
      children: [
        // Fixed connection info and controls
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildConnectedDeviceCard(),
              const SizedBox(height: 8),
              if (_statusMessage.isNotEmpty) ...[
                _buildStatusCard(),
                const SizedBox(height: 8),
              ],
              _buildDownloadControls(),
              if (_isDownloading || _downloadProgress > 0) ...[
                const SizedBox(height: 8),
                _buildProgressBar(),
              ],
              const SizedBox(height: 8),
              _buildDownloadOptions(),
              if (_dives.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Dives (${_dives.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),

        // Scrollable dive list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _dives.length,
            itemBuilder: (context, index) => _buildDiveCard(_dives[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedDeviceCard() {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bluetooth_connected,
                  color: Colors.green,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_connectedDevice!.vendor} '
                        '${_connectedDevice!.product}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _connectedDevice!.address,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_devInfoSerial != null)
                        Text(
                          'S/N: $_devInfoSerial  FW: $_devInfoFirmware',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _isDownloading ? null : _disconnect,
                child: const Text('Disconnect'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadControls() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: _isDownloading ? null : _startDownload,
          icon: Icon(_isDownloading ? Icons.hourglass_top : Icons.download),
          label: Text(
            _isDownloading
                ? 'Downloading...'
                : _dives.isEmpty
                ? 'Download Dives'
                : 'Re-download',
          ),
        ),
        if (_isDownloading)
          OutlinedButton.icon(
            onPressed: _cancelDownload,
            icon: const Icon(Icons.cancel),
            label: const Text('Cancel'),
          ),
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: _isDownloading ? _downloadProgress : 1.0,
        ),
        const SizedBox(height: 4),
        Text(
          _isDownloading
              ? '${(_downloadProgress * 100).toInt()}%  •  '
                    '${_dives.length}'
                    '${_totalDiveCount != null ? ' of ~$_totalDiveCount' : ''} '
                    'dives'
              : '${_dives.length} dives downloaded',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildDownloadOptions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          height: 32,
          child: FilterChip(
            label: const Text('Force full download'),
            selected: _forceDownload,
            onSelected: _isDownloading
                ? null
                : (value) => setState(() => _forceDownload = value),
          ),
        ),
        TextButton.icon(
          onPressed: _isDownloading ? null : _resetFingerprint,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Reset Fingerprint'),
        ),
      ],
    );
  }

  // MARK: - Shared Cards

  Widget _buildLibraryStatusCard() {
    final isOk = _libraryVersion.contains('libdivecomputer');
    return Card(
      child: ListTile(
        leading: Icon(
          isOk ? Icons.check_circle : Icons.error,
          color: isOk ? Colors.green : Colors.red,
        ),
        title: const Text('Library Status'),
        subtitle: Text(_libraryVersion),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
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
    );
  }

  // MARK: - Dive Card

  Widget _buildDiveCard(DcDive dive) {
    final dateStr = dive.dateTime != null
        ? '${dive.dateTime!.year}-'
              '${dive.dateTime!.month.toString().padLeft(2, '0')}-'
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
