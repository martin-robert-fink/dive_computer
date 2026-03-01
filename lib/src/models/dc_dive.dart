class DcDive {
  final int number;
  final DateTime? dateTime;
  final double? maxDepth;
  final double? avgDepth;
  final Duration? diveTime;
  final double? minTemperature;
  final double? maxTemperature;
  final double? surfaceTemperature;
  final String? diveMode;
  final double? atmospheric;
  final List<DcGasMix>? gasMixes;
  final List<DcTank>? tanks;
  final List<Map<String, dynamic>>? samples;
  final int? sampleCount;
  final String? fingerprint;
  final String? error;

  const DcDive({
    required this.number,
    this.dateTime,
    this.maxDepth,
    this.avgDepth,
    this.diveTime,
    this.minTemperature,
    this.maxTemperature,
    this.surfaceTemperature,
    this.diveMode,
    this.atmospheric,
    this.gasMixes,
    this.tanks,
    this.samples,
    this.sampleCount,
    this.fingerprint,
    this.error,
  });

  factory DcDive.fromMap(Map<String, dynamic> map) {
    return DcDive(
      number: map['number'] as int? ?? 0,
      dateTime: map['dateTime'] != null
          ? DateTime.tryParse(map['dateTime'] as String)
          : null,
      maxDepth: (map['maxDepth'] as num?)?.toDouble(),
      avgDepth: (map['avgDepth'] as num?)?.toDouble(),
      diveTime: map['diveTime'] != null
          ? Duration(seconds: map['diveTime'] as int)
          : null,
      minTemperature: (map['minTemperature'] as num?)?.toDouble(),
      maxTemperature: (map['maxTemperature'] as num?)?.toDouble(),
      surfaceTemperature: (map['surfaceTemperature'] as num?)?.toDouble(),
      diveMode: map['diveMode'] as String?,
      atmospheric: (map['atmospheric'] as num?)?.toDouble(),
      gasMixes: (map['gasMixes'] as List?)
          ?.map((m) => DcGasMix.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      tanks: (map['tanks'] as List?)
          ?.map((m) => DcTank.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      samples: (map['samples'] as List?)
          ?.map((m) => Map<String, dynamic>.from(m as Map))
          .toList(),
      sampleCount:
          map['sampleCount'] as int? ?? (map['samples'] as List?)?.length,
      fingerprint: map['fingerprint'] as String?,
      error: map['error'] as String?,
    );
  }

  String get depthStr =>
      maxDepth != null ? '${maxDepth!.toStringAsFixed(1)}m' : '?m';

  String get timeStr {
    if (diveTime == null) return '?';
    final mins = diveTime!.inMinutes;
    final secs = diveTime!.inSeconds % 60;
    return secs > 0 ? '${mins}m ${secs}s' : '${mins}min';
  }

  String get tempStr =>
      minTemperature != null ? '${minTemperature!.toStringAsFixed(1)}°C' : '';

  String get gasStr => gasMixes != null && gasMixes!.isNotEmpty
      ? gasMixes!.map((g) => g.label).join(', ')
      : '';

  @override
  String toString() => 'Dive #$number: $depthStr, $timeStr, $dateTime';
}

class DcGasMix {
  final double oxygen;
  final double helium;
  final double nitrogen;

  const DcGasMix({
    required this.oxygen,
    required this.helium,
    required this.nitrogen,
  });

  factory DcGasMix.fromMap(Map<String, dynamic> map) {
    return DcGasMix(
      oxygen: (map['oxygen'] as num?)?.toDouble() ?? 0,
      helium: (map['helium'] as num?)?.toDouble() ?? 0,
      nitrogen: (map['nitrogen'] as num?)?.toDouble() ?? 0,
    );
  }

  String get label {
    final o2 = (oxygen * 100).round();
    final he = (helium * 100).round();
    if (he > 0) return '$o2/$he';
    if (o2 == 21) return 'Air';
    return 'EAN$o2';
  }

  @override
  String toString() => label;
}

class DcTank {
  final double beginPressure;
  final double endPressure;
  final double? volume;
  final double? workPressure;
  final int? gasmix;

  const DcTank({
    required this.beginPressure,
    required this.endPressure,
    this.volume,
    this.workPressure,
    this.gasmix,
  });

  factory DcTank.fromMap(Map<String, dynamic> map) {
    return DcTank(
      beginPressure: (map['beginPressure'] as num?)?.toDouble() ?? 0,
      endPressure: (map['endPressure'] as num?)?.toDouble() ?? 0,
      volume: (map['volume'] as num?)?.toDouble(),
      workPressure: (map['workPressure'] as num?)?.toDouble(),
      gasmix: map['gasmix'] as int?,
    );
  }

  @override
  String toString() => '${beginPressure.round()}→${endPressure.round()} bar';
}
