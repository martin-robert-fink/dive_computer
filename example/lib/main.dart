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
  List<DcDiveComputer> _shearwaterDescriptors = [];
  String _statusMessage = '';

  // BLE scan state
  bool _isScanning = false;
  final List<DcDeviceInfo> _discoveredDevices = [];
  StreamSubscription<Map<String, dynamic>>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final version = await _plugin.getLibraryVersion();
      setState(() => _libraryVersion = version);

      final descriptors = await _plugin.getSupportedDescriptors();
      final shearwater = descriptors
          .map((d) => DcDiveComputer.fromMap(d))
          .where((d) => d.vendor == 'Shearwater')
          .toList();

      setState(() {
        _shearwaterDescriptors = shearwater;
        _statusMessage =
            'Found ${shearwater.length} Shearwater models. '
            'BLE models: ${shearwater.where((d) => d.supportsBle).length}';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    }
  }

  void _startScan() {
    setState(() {
      _isScanning = true;
      _discoveredDevices.clear();
    });

    _scanSubscription = _plugin.scanForDevices().listen(
      (event) {
        final device = DcDeviceInfo.fromMap(event);
        setState(() {
          // Update existing device (e.g. RSSI change) or add new one
          final existingIndex = _discoveredDevices.indexWhere(
            (d) => d.address == device.address,
          );
          if (existingIndex >= 0) {
            _discoveredDevices[existingIndex] = device;
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
      onDone: () {
        setState(() => _isScanning = false);
      },
    );
  }

  Future<void> _stopScan() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await _plugin.stopScan();
    } catch (_) {}
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dive Computer Plugin Test')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Library status card
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
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Status'),
                  subtitle: Text(_statusMessage),
                ),
              ),
            const SizedBox(height: 16),

            // BLE Scan section
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
                  onPressed: _isScanning ? _stopScan : _startScan,
                  icon: Icon(
                    _isScanning ? Icons.stop : Icons.bluetooth_searching,
                  ),
                  label: Text(_isScanning ? 'Stop' : 'Scan'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Discovered devices list
            if (_discoveredDevices.isEmpty && _isScanning)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.bluetooth_searching, color: Colors.blue),
                  title: Text('Scanning for dive computers...'),
                  subtitle: Text(
                    'Make sure your dive computer is in Bluetooth pairing mode',
                  ),
                ),
              ),
            if (_discoveredDevices.isEmpty && !_isScanning)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.bluetooth_disabled, color: Colors.grey),
                  title: Text('No devices found'),
                  subtitle: Text('Press Scan to search for BLE dive computers'),
                ),
              ),
            if (_discoveredDevices.isNotEmpty) ...[
              Text(
                'Discovered Devices (${_discoveredDevices.length})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
            ],
            Expanded(
              child: ListView(
                children: [
                  // Discovered BLE devices
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
                          'RSSI: ${device.rssi} dBm\n${device.address}',
                        ),
                        isThreeLine: true,
                        trailing: FilledButton(
                          onPressed:
                              null, // Connection comes in the next iteration
                          child: const Text('Connect'),
                        ),
                      ),
                    ),
                  ),

                  // Separator if we have both sections
                  if (_discoveredDevices.isNotEmpty &&
                      _shearwaterDescriptors.isNotEmpty)
                    const Divider(height: 32),

                  // Shearwater models from descriptors
                  if (_shearwaterDescriptors.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        'Shearwater Models (${_shearwaterDescriptors.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ..._shearwaterDescriptors.map(
                    (desc) => ListTile(
                      title: Text(desc.toString()),
                      subtitle: Text(
                        'Family: ${desc.family}, Model: ${desc.model}, '
                        'BLE: ${desc.supportsBle ? "Yes" : "No"}',
                      ),
                      trailing: desc.supportsBle
                          ? const Icon(Icons.bluetooth, color: Colors.blue)
                          : const Icon(Icons.usb, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
