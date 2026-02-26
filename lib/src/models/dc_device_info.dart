class DcDeviceInfo {
  final String name;
  final String address;
  final int rssi;
  final String vendor;
  final String product;
  final int family;
  final int model;

  const DcDeviceInfo({
    required this.name,
    required this.address,
    required this.rssi,
    this.vendor = '',
    this.product = '',
    this.family = 0,
    this.model = 0,
  });

  factory DcDeviceInfo.fromMap(Map<String, dynamic> map) {
    return DcDeviceInfo(
      name: map['name'] as String? ?? 'Unknown',
      address: map['address'] as String? ?? '',
      rssi: map['rssi'] as int? ?? 0,
      vendor: map['vendor'] as String? ?? '',
      product: map['product'] as String? ?? '',
      family: map['family'] as int? ?? 0,
      model: map['model'] as int? ?? 0,
    );
  }

  @override
  String toString() => vendor.isNotEmpty ? '$vendor $product ($name)' : name;
}
