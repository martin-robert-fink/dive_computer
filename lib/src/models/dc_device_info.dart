class DcDeviceInfo {
  final String name;
  final String address;
  final int rssi;

  const DcDeviceInfo({
    required this.name,
    required this.address,
    required this.rssi,
  });

  factory DcDeviceInfo.fromMap(Map<String, dynamic> map) {
    return DcDeviceInfo(
      name: map['name'] as String? ?? 'Unknown',
      address: map['address'] as String? ?? '',
      rssi: map['rssi'] as int? ?? 0,
    );
  }
}
