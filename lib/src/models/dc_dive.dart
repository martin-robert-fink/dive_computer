class DcDive {
  final int number;
  final DateTime? dateTime;
  final double? maxDepth;
  final Duration? diveTime;
  final double? minTemperature;
  final List<int>? rawData;

  const DcDive({
    required this.number,
    this.dateTime,
    this.maxDepth,
    this.diveTime,
    this.minTemperature,
    this.rawData,
  });

  factory DcDive.fromMap(Map<String, dynamic> map) {
    return DcDive(
      number: map['number'] as int? ?? 0,
      dateTime: map['dateTime'] != null
          ? DateTime.tryParse(map['dateTime'] as String)
          : null,
      maxDepth: (map['maxDepth'] as num?)?.toDouble(),
      diveTime: map['diveTime'] != null
          ? Duration(seconds: map['diveTime'] as int)
          : null,
      minTemperature: (map['minTemperature'] as num?)?.toDouble(),
      rawData: (map['rawData'] as List?)?.cast<int>(),
    );
  }

  @override
  String toString() =>
      'Dive #$number: ${maxDepth?.toStringAsFixed(1)}m, '
      '${diveTime?.inMinutes}min, $dateTime';
}
