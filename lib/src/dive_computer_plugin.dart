import 'package:flutter/services.dart';

class DiveComputerPlugin {
  DiveComputerPlugin._();

  static final DiveComputerPlugin instance = DiveComputerPlugin._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.dive_computer/methods',
  );

  static const EventChannel _scanChannel = EventChannel(
    'com.example.dive_computer/scan',
  );

  static const EventChannel _downloadChannel = EventChannel(
    'com.example.dive_computer/download',
  );

  Future<String> getLibraryVersion() async {
    final version = await _channel.invokeMethod<String>('getLibraryVersion');
    return version ?? 'unknown';
  }

  Future<List<Map<String, dynamic>>> getSupportedDescriptors() async {
    final result = await _channel.invokeMethod<List>('getSupportedDescriptors');
    if (result == null) return [];
    return result.cast<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  Stream<Map<String, dynamic>> scanForDevices() {
    return _scanChannel.receiveBroadcastStream().map(
      (event) => Map<String, dynamic>.from(event as Map),
    );
  }

  Future<void> stopScan() async {
    await _channel.invokeMethod('stopScan');
  }

  Future<bool> connectToDevice({
    required String address,
    required String vendor,
    required String product,
  }) async {
    final result = await _channel.invokeMethod<bool>('connectToDevice', {
      'address': address,
      'vendor': vendor,
      'product': product,
    });
    return result ?? false;
  }

  Stream<Map<String, dynamic>> downloadDives() {
    return _downloadChannel.receiveBroadcastStream().map(
      (event) => Map<String, dynamic>.from(event as Map),
    );
  }

  Future<void> disconnect() async {
    await _channel.invokeMethod('disconnect');
  }
}
