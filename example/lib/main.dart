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

  @override
  void initState() {
    super.initState();
    _initialize();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dive Computer Plugin Test')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            if (_statusMessage.isNotEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Status'),
                  subtitle: Text(_statusMessage),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Shearwater Models (${_shearwaterDescriptors.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _shearwaterDescriptors.length,
                itemBuilder: (context, index) {
                  final desc = _shearwaterDescriptors[index];
                  return ListTile(
                    title: Text(desc.toString()),
                    subtitle: Text(
                      'Family: ${desc.family}, Model: ${desc.model}, '
                      'BLE: ${desc.supportsBle ? "Yes" : "No"}',
                    ),
                    trailing: desc.supportsBle
                        ? const Icon(Icons.bluetooth, color: Colors.blue)
                        : const Icon(Icons.usb, color: Colors.grey),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
