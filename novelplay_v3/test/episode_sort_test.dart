import 'package:flutter_test/flutter_test.dart';
import '../lib/episode_sort.dart';

void main() {
  group('episodeNumberFromName', () {
    test('lê o número depois de temporada e episódio', () {
      expect(episodeNumberFromName('S01E03 - A chegada.mp4'), 3);
      expect(episodeNumberFromName('Temporada 2 - Episódio 10.mp4'), 10);
      expect(episodeNumberFromName('Season 3 08.mp4'), 8);
    });

    test('reconhece formatos EP, capítulo e temporada x episódio', () {
      expect(episodeNumberFromName('EP. 09 - O retorno.mp4'), 9);
      expect(episodeNumberFromName('Capítulo 7.mp4'), 7);
      expect(episodeNumberFromName('2x11 - Final.mp4'), 11);
    });

    test('aceita número no início do nome e zeros à esquerda', () {
      expect(episodeNumberFromName('001 - Primeiro episódio.mp4'), 1);
      expect(episodeNumberFromName('12 - O final.mp4'), 12);
    });

    test('retorna zero quando o nome não tem número', () {
      expect(episodeNumberFromName('Sem numeração.mp4'), 0);
    });
  });
}
