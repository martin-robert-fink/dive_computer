import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'dive_computer_method_channel.dart';

abstract class DiveComputerPlatform extends PlatformInterface {
  /// Constructs a DiveComputerPlatform.
  DiveComputerPlatform() : super(token: _token);

  static final Object _token = Object();

  static DiveComputerPlatform _instance = MethodChannelDiveComputer();

  /// The default instance of [DiveComputerPlatform] to use.
  ///
  /// Defaults to [MethodChannelDiveComputer].
  static DiveComputerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [DiveComputerPlatform] when
  /// they register themselves.
  static set instance(DiveComputerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
