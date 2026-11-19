/// Extrai o número do episódio de nomes comuns usados em pastas do Drive.
///
/// Reconhece S01E03, 2x11, "Episódio 10", "EP. 10", "Capítulo 4" e
/// nomes iniciados por "01 - ...". Retorna zero quando não há número.
int episodeNumberFromName(String name) {
  final patterns = <RegExp>[
    RegExp(r'\\bs\\d{1,3}[\\s._-]*e[\\s._-]*0*(\\d+)\\b', caseSensitive: false),
    RegExp(r'\\b\\d{1,3}\\s*x\\s*0*(\\d+)\\b', caseSensitive: false),
    RegExp(
      r'\\b(?:epis[oó]dio|episode|ep|cap[ií]tulo|chapter|cap)\\s*[-_.#]*\\s*0*(\\d+)',
      caseSensitive: false,
    ),
    RegExp(r'^\\s*0*(\\d+)(?=\\s*[-_. )]|$)'),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(name);
    if (match != null) return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  final numbers = RegExp(r'\\d+').allMatches(name).toList();
  if (numbers.isEmpty) return 0;

  // Se o nome só informa temporada e depois um número, o último tende a ser
  // o episódio (ex.: "Temporada 2 - 08").
  if (RegExp(r'\\b(?:temporada|season)\\b', caseSensitive: false).hasMatch(name) &&
      numbers.length > 1) {
    return int.tryParse(numbers.last.group(0) ?? '') ?? 0;
  }
  return int.tryParse(numbers.first.group(0) ?? '') ?? 0;
}
