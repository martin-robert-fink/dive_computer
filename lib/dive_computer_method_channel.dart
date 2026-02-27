import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dive_computer_platform_interface.dart';

/// An implementation of [DiveComputerPlatform] that uses method channels.
class MethodChannelDiveComputer extends DiveComputerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('dive_computer');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
