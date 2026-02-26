class DcDiveComputer {
  final String vendor;
  final String product;
  final int family;
  final int model;
  final int transports;

  const DcDiveComputer({
    required this.vendor,
    required this.product,
    required this.family,
    required this.model,
    required this.transports,
  });

  factory DcDiveComputer.fromMap(Map<String, dynamic> map) {
    return DcDiveComputer(
      vendor: map['vendor'] as String? ?? '',
      product: map['product'] as String? ?? '',
      family: map['family'] as int? ?? 0,
      model: map['model'] as int? ?? 0,
      transports: map['transports'] as int? ?? 0,
    );
  }

  bool get supportsBle => (transports & 0x20) != 0;

  @override
  String toString() => '$vendor $product';
}
