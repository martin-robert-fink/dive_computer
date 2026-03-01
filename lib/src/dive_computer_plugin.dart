import 'package:flutter/services.dart';

/// Plugin interface for communicating with dive computers via libdivecomputer.
///
/// Scanning uses an EventChannel (lightweight discovery events).
/// Downloads use a polling model: call [startDownload], poll [getDownloadProgress]
/// on a timer, then call [getDownloadedDives] when complete to retrieve full data.
/// This matches Subsurface's architecture and avoids main queue congestion on iOS.
class DiveComputerPlugin {
  DiveComputerPlugin._();

  static final DiveComputerPlugin instance = DiveComputerPlugin._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.dive_computer/methods',
  );

  static const EventChannel _scanChannel = EventChannel(
    'com.example.dive_computer/scan',
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

  /// Start a dive download. Returns immediately.
  /// Poll [getDownloadProgress] to track progress.
  /// Call [getDownloadedDives] after completion for full dive data.
  Future<void> startDownload({bool forceDownload = false}) async {
    await _channel.invokeMethod('startDownload', {
      'forceDownload': forceDownload,
    });
  }

  /// Cancel an active download.
  Future<void> cancelDownload() async {
    await _channel.invokeMethod('cancelDownload');
  }

  /// Poll current download progress. Returns a map with:
  /// - `isActive` (bool): whether download is still running
  /// - `progressFraction` (double): 0.0 to 1.0
  /// - `diveCount` (int): dives downloaded so far
  /// - `estimatedTotalDives` (int?): estimated total, if known
  /// - `serial` (int?): device serial number
  /// - `firmware` (int?): device firmware version
  /// - `status` (String?): null while active; "success"/"done"/"error(N)" when finished
  Future<Map<String, dynamic>> getDownloadProgress() async {
    final result = await _channel.invokeMethod<Map>('getDownloadProgress');
    if (result == null) return {'isActive': false, 'diveCount': 0};
    return Map<String, dynamic>.from(result);
  }

  /// Retrieve all downloaded dive data (with full samples).
  /// Call after download completes for best results.
  Future<List<Map<String, dynamic>>> getDownloadedDives() async {
    final result = await _channel.invokeMethod<List>('getDownloadedDives');
    if (result == null) return [];
    return result.cast<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  Future<void> resetFingerprint() async {
    await _channel.invokeMethod('resetFingerprint');
  }

  Future<void> disconnect() async {
    await _channel.invokeMethod('disconnect');
  }
}
