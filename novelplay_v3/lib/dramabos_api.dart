import 'dart:convert';
import 'package:http/http.dart' as http;

// DramaBos metadata requests go through the NovelPlay Render gateway.
// An optional access key stays server-side, never in the APK.
class DramaProvider {
  final String name, slug;
  const DramaProvider(this.name, this.slug);
}
class DramaItem {
  final String id, title, cover, synopsis, genre;
  final int total;
  const DramaItem(this.id, this.title, this.cover, this.synopsis, this.genre, this.total);
}
class DramaEpisode {
  final int number;
  final String title, thumbnail, code;
  final bool locked;
  const DramaEpisode(this.number, this.title, this.thumbnail, this.code, this.locked);
}

class DramaBosApi {
  static const host = 'novelplay-api.onrender.com';
  static const upstreamHost = 'dramabos.live';
  static const providerCsv = '''
StarShort|starshort
DramaBite|dramabite
FreeReels|freereels
FunDrama|fundrama
MicroDrama|microdrama
Vigloo|vigloo
BiliTV|bilitv
DramaBox|dramabox
DramaWave|dramawave
NetShort|netshort
iDrama|idrama
ShortMax|shortmax
GoodShort|goodshort
Melolo|melolo
Velolo|velolo
ReelShort|reelshort
FlickReels|flickreels
Stardusttv|stardusttv
Serial+|serialplus
DotDrama|dotdrama
RapidTV|rapidtv
ShortsWave|shortswave
DramaNova|dramanova
CubeTV|cubetv
ReelBuzz|reelbuzz
FlareFlow|flareflow
MoboReels|moboreels
HappyShort|happyshort
Reelife|reelife
PineDrama|pinedrama
FlexTV|flextv
Reelala|reelala
Anyreel|anyreel
RaptDrama|raptdrama
BonusTV|bonustv
MiniTV|minitv
Gold Drama|golddrama
IQIYI|iqiyi
Bstation|bstation
Joyreels|joyreels
KalosTV|kalostv
Vibeshort|vibeshort
''';
  static final List<DramaProvider> providers = providerCsv.trim()
      .split('\n').map((line) {
        final fields = line.split('|');
        return DramaProvider(fields[0], fields[1]);
      }).toList(growable: false);

  static String asText(dynamic input) => input?.toString() ?? '';
  static int asInt(dynamic input) => int.tryParse(asText(input)) ?? 0;
  static String asGenre(dynamic input) =>
      input is List ? input.map(asText).join(', ') : asText(input);
  static Uri uri(String path, [Map<String, String>? query]) =>
      Uri.https(host, path, query);

  static Future<dynamic> get(Uri address) async {
    if (address.scheme != 'https' ||
        (address.host != host && address.host != upstreamHost)) {
      throw const FormatException('Endereço da API inválido');
    }
    try {
      final response = await http.get(address,
          headers: const {'Accept': 'application/json'}).timeout(
          const Duration(seconds: 18));
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        throw FormatException(
            'A fonte retornou resposta inválida (HTTP ${response.statusCode}).');
      }
      if (response.statusCode != 200) {
        final reason = data is Map
            ? asText(data['error'] ?? data['message'])
            : '';
        throw FormatException(
            reason.isNotEmpty ? reason :
            'A DramaBos respondeu HTTP ${response.statusCode}.');
      }
      if (data is Map &&
          (data['status'] == false || data['success'] == false)) {
        throw FormatException('DramaBos retornou erro: ' +
            asText(data['message'] ?? data['error']));
      }
      return data;
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Falha ao acessar DramaBos: ' + error.toString());
    }
  }

  static List<dynamic> findList(dynamic node, [int depth = 0]) {
    if (depth > 6) return [];
    if (node is List) return node;
    if (node is! Map) return [];
    for (final key in const ['results','episodes','dramas','items','list',
        'books','records','series','data','result']) {
      if (node.containsKey(key)) {
        final found = findList(node[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
    }
    if (node['sections'] is List) {
      final found = <dynamic>[];
      for (final section in node['sections'] as List) {
        found.addAll(findList(section, depth + 1));
      }
      return found;
    }
    return [];
  }

  static List<DramaItem> items(dynamic data) {
    final output = <DramaItem>[];
    final seen = <String>{};
    for (final node in findList(data)) {
      if (node is! Map) continue;
      final id = asText(node['id'] ?? node['dramaId'] ??
          node['book_id'] ?? node['code']);
      final title = asText(node['title'] ?? node['book_title'] ?? node['name']);
      if (id.isEmpty || title.isEmpty || !seen.add(id)) continue;
      output.add(DramaItem(
        id, title,
        asText(node['cover'] ?? node['poster'] ??
            node['book_pic'] ?? node['image']),
        asText(node['synopsis'] ?? node['description'] ?? node['special_desc']),
        asGenre(node['genre'] ?? node['category']),
        asInt(node['episodes'] ?? node['episodeCount'] ?? node['chapter_count']),
      ));
    }
    return output;
  }

  static List<DramaEpisode> parseEpisodes(dynamic data) {
    final output = <DramaEpisode>[];
    for (final node in findList(data)) {
      if (node is! Map) continue;
      final n = asInt(node['number'] ?? node['episode'] ??
          node['serial_number'] ?? node['episodeNumber']);
      if (n <= 0) continue;
      // Free only when the provider explicitly says locked:false.
      final isFree =
          (node.containsKey('locked') && node['locked'] == false) ||
          (node.containsKey('free') && node['free'] == true);
      output.add(DramaEpisode(n,
        asText(node['title'] ?? node['name']).isEmpty
            ? 'Episódio $n' : asText(node['title'] ?? node['name']),
        asText(node['thumbnail'] ?? node['cover']),
        asText(node['code'] ?? node['episodeCode'] ?? node['chapter_id']),
        !isFree));
    }
    output.sort((a, b) => a.number.compareTo(b.number));
    return output;
  }

  static String prefix(DramaProvider p) => '/' + p.slug + '/api/v1';
  static String gateway(DramaProvider p, String section) =>
      '/api/dramabos/' + section + '/' + p.slug;

  static String reelshortSlug(String title) {
    final formatted = title.toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return formatted
        .replaceAll(RegExp(r'^-+'), '')
        .replaceAll(RegExp(r'-+$'), '');
  }

  static Uri reelshortEndpoint(String path, [Map<String, String>? params]) =>
      uri('/api/v1/reelshort' + path, params);

  static Future<List<DramaItem>> home(DramaProvider p) async {
    if (p.slug == 'reelshort') {
      return items(await get(reelshortEndpoint('/recommended')));
    }
    return items(await get(uri(gateway(p, 'home'))));
  }

  static Future<List<DramaItem>> search(DramaProvider p, String keyword) async {
    final text = keyword.trim();
    if (text.isEmpty) return home(p);
    if (text.length > 100) {
      throw const FormatException('Use uma pesquisa com até 100 caracteres');
    }
    if (p.slug == 'reelshort') {
      return items(await get(reelshortEndpoint(
        '/search', {'keywords': text},
      )));
    }
    return items(await get(uri(
      gateway(p, 'search'), {'keyword': text},
    )));
  }

  static Future<List<DramaEpisode>> episodes(
      DramaProvider p, DramaItem drama) async {
    if (p.slug == 'reelshort') {
      final bookId = Uri.encodeComponent(drama.id);
      final data = await get(reelshortEndpoint(
        '/episodes/' + bookId,
        {'filtered_title': reelshortSlug(drama.title)},
      ));
      return parseEpisodes(data);
    }
    final path = gateway(p, 'episodes') + '/' +
        Uri.encodeComponent(drama.id);
    return parseEpisodes(await get(uri(path)));
  }

  static Future<Uri> play(
      DramaProvider p, DramaItem drama, DramaEpisode episode) async {
    if (episode.locked) {
      throw const FormatException('Este episódio é bloqueado pela plataforma');
    }
    if (p.slug == 'reelshort') {
      if (episode.code.isEmpty) {
        throw const FormatException('Identificador do episódio indisponível');
      }
      final data = await get(reelshortEndpoint(
        '/video/' + Uri.encodeComponent(drama.id) +
            '/' + episode.number.toString(),
        {
          'filtered_title': reelshortSlug(drama.title),
          'chapter_id': episode.code,
        },
      ));
      final mediaUrl = data is Map ? asText(data['video_url']) : '';
      final media = Uri.tryParse(mediaUrl);
      if (media == null || media.scheme != 'https' ||
          media.host.isEmpty || media.userInfo.isNotEmpty) {
        throw const FormatException('Vídeo gratuito indisponível');
      }
      return media;
    }
    final path = p.slug == 'shortmax' && episode.code.isNotEmpty
        ? prefix(p) + '/play/' + Uri.encodeComponent(episode.code)
        : prefix(p) + '/play/' + Uri.encodeComponent(drama.id) +
            '/' + episode.number.toString();
    dynamic response = await get(Uri.https(upstreamHost, path));
    for (var i = 0; i < 3 && response is Map; i++) {
      if (response['streamUrl'] != null || response['video_url'] != null ||
          response['playUrl'] != null || response['url'] != null) break;
      response = response['data'] ?? response['result'];
    }
    if (response is! Map) {
      throw const FormatException('A DramaBos não retornou um link de vídeo');
    }
    final link = Uri.tryParse(asText(response['streamUrl'] ??
        response['video_url'] ?? response['playUrl'] ?? response['url']));
    if (link == null || link.scheme != 'https' ||
        link.host.isEmpty || link.userInfo.isNotEmpty) {
      throw const FormatException('URL de vídeo HTTPS indisponível');
    }
    return link;
  }
  static Future<bool> connected() async {
    try {
      final info = await get(uri('/api/dramabos/status'));
      return info is Map && info['providers'] == 42;
    } catch (_) {
      return false;
    }
  }

}
