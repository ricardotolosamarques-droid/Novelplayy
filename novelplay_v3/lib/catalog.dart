import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class Episode {
  final int number;
  final String title;
  final String videoUrl;
  final String chapterId;
  final bool isFree;

  const Episode(this.number, this.title, this.videoUrl,
      {this.chapterId = '', this.isFree = true});

  factory Episode.fromJson(Map<String, dynamic> value) {
    final number = int.tryParse((value['number'] ??
        value['episodeNumber'] ?? value['episode_index'] ?? 1).toString()) ?? 1;
    return Episode(number,
        (value['title'] ?? value['name'] ?? 'Episódio $number').toString(),
        (value['videoUrl'] ?? value['playUrl'] ??
            value['video_url'] ?? '').toString());
  }
}

class Novel {
  final String id;
  final String title;
  final String synopsis;
  final String genre;
  final String cover;
  final List<Episode> episodes;
  final String slug;
  final bool fromReelShort;

  const Novel(this.id, this.title, this.synopsis, this.genre,
      this.cover, this.episodes,
      {this.slug = '', this.fromReelShort = false});

  factory Novel.fromJson(Map<String, dynamic> value) {
    final source = value['episodes'] ?? value['episode_list'] ?? [];
    final episodes = source is List
        ? source.whereType<Map>().map((item) =>
            Episode.fromJson(Map<String, dynamic>.from(item))).toList()
        : <Episode>[];
    return Novel(
      (value['id'] ?? value['show_collection_id'] ?? '').toString(),
      (value['title'] ?? value['name'] ?? 'Sem título').toString(),
      (value['synopsis'] ?? value['description'] ?? '').toString(),
      (value['genre'] ?? value['category'] ?? '').toString(),
      (value['cover'] ?? value['poster'] ?? '').toString(),
      episodes,
    );
  }

  factory Novel.fromReelShortBook(Map<String, dynamic> book) {
    return Novel(
      (book['book_id'] ?? '').toString(),
      (book['book_title'] ?? 'Sem título').toString(),
      (book['special_desc'] ?? '').toString(),
      'ReelShort',
      (book['book_pic'] ?? '').toString(),
      const [],
      slug: (book['filtered_title'] ?? '').toString(),
      fromReelShort: true,
    );
  }
}

class Catalog {
  final List<Novel> novels;
  final String origin;
  final String? warning;
  const Catalog(this.novels, this.origin, [this.warning]);
}

class Sources {
  static String reelshortApiUrl =
      const String.fromEnvironment('REELSHORT_API_URL',
          defaultValue: 'https://novelplay-api.onrender.com/api/v1/reelshort');
  static const String catalogUrl =
      String.fromEnvironment('CATALOG_URL');
  static const String apiBaseUrl =
      String.fromEnvironment('API_BASE_URL');
  static const String apiIndexPath =
      String.fromEnvironment('API_INDEX_PATH',
          defaultValue: '/api/playlet/index_recommend');
  static const String apiInfoPath =
      String.fromEnvironment('API_INFO_PATH',
          defaultValue: '/api/playlet/info');

  static Uri? valid(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || uri.scheme != 'https' ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  static Uri? proxyEndpoint(String suffix) {
    final base = valid(reelshortApiUrl);
    if (base == null || !suffix.startsWith('/')) return null;
    final path = base.path.replaceFirst(RegExp(r'/$'), '') + suffix;
    return base.replace(path: path, query: null, fragment: null);
  }

  static Uri? genericEndpoint(String suffix) {
    final base = valid(apiBaseUrl);
    if (base == null || !suffix.startsWith('/') ||
        suffix.startsWith('//')) return null;
    return base.replace(path: suffix, query: null, fragment: null);
  }

  static Future<dynamic> request(Uri uri) async {
    final response = await http.get(uri, headers: const {
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('API respondeu HTTP ' + response.statusCode.toString());
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  static List<dynamic>? findList(dynamic node, [int depth = 0]) {
    if (depth > 5) return null;
    if (node is List) return node;
    if (node is Map) {
      for (final key in const [
        'novels','playlets','data','result','list','items',
        'rows','records','recommend_list','video_list'
      ]) {
        if (node.containsKey(key)) {
          final list = findList(node[key], depth + 1);
          if (list != null) return list;
        }
      }
    }
    return null;
  }

  static List<Novel> parseGeneric(dynamic data) {
    final entries = findList(data);
    if (entries == null) {
      throw const FormatException('JSON não contém lista de novelinhas');
    }
    return entries
        .whereType<Map>()
        .map((entry) => Novel.fromJson(Map<String, dynamic>.from(entry)))
        .where((n) => n.title != 'Sem título')
        .toList();
  }

  static Future<Catalog> demo([String? warning]) async {
    final raw = await rootBundle.loadString('assets/catalog.json');
    return Catalog(parseGeneric(jsonDecode(raw)), 'Demonstração', warning);
  }

  static Future<Catalog> load({
    String shelf = 'recommended',
    String query = '',
  }) async {
    if (valid(reelshortApiUrl) != null) {
      try {
        final term = query.trim();
        final allowedShelf = const ['recommended','newrelease','dramadub']
                .contains(shelf) ? shelf : 'recommended';
        final uri = proxyEndpoint(term.isNotEmpty ? '/search' : '/'+allowedShelf);
        if (uri == null) {
          throw const FormatException('Endereço da API inválido');
        }
        final endpoint = term.isNotEmpty
            ? uri.replace(queryParameters: {'keywords': term})
            : uri;
        final body = await request(endpoint);
        if (body is! Map) {
          throw const FormatException('Resposta inesperada da API');
        }
        final entries = term.isNotEmpty ? body['results'] : body['books'];
        if (entries is! List) {
          throw const FormatException('API não retornou lista de títulos');
        }
        final titles = entries
            .whereType<Map>()
            .map((item) =>
                Novel.fromReelShortBook(Map<String, dynamic>.from(item)))
            .where((n) => n.slug.isNotEmpty)
            .toList();
        return Catalog(titles,
            'Catálogo ReelShort (API comunitária)',
            'Episódios públicos disponíveis para reprodução no NovelPlay. '
            'Episódios pagos continuam bloqueados.');
      } catch (error) {
        return demo('Falha na conexão com a API ReelShort: $error');
      }
    }

    final uri = valid(catalogUrl) ?? genericEndpoint(apiIndexPath);
    if (uri != null) {
      try {
        return Catalog(parseGeneric(await request(uri)), 'Catálogo autorizado');
      } catch (error) {
        return demo('Erro ao carregar o catálogo: $error');
      }
    }
    return demo(
      'Sem API configurada: a demonstração não contém novelinhas reais.');
  }

  static Future<Uri> resolveReelShortVideo(Novel novel, Episode episode) async {
    if (!novel.fromReelShort || novel.id.isEmpty ||
        episode.chapterId.isEmpty || !episode.isFree) {
      throw const FormatException('Episódio indisponível para reprodução aqui');
    }
    final url = proxyEndpoint(
      '/video/' + Uri.encodeComponent(novel.id) + '/' +
          episode.number.toString(),
    );
    if (url == null) {
      throw const FormatException('API ReelShort não configurada');
    }
    final response = await request(url.replace(queryParameters: {
      'filtered_title': novel.slug,
      'chapter_id': episode.chapterId,
    }));
    if (response is! Map) {
      throw const FormatException('A API não retornou um vídeo válido');
    }
    final media = valid((response['video_url'] ?? '').toString());
    if (media == null) {
      throw const FormatException('O episódio gratuito não tem vídeo disponível');
    }
    return media;
  }

  static Future<Novel> details(Novel novel) async {
    if (novel.episodes.isNotEmpty) return novel;
    if (novel.fromReelShort) {
      var bookId = novel.id;
      // The bookshelf does not always include book_id. Look up just
      // the selected title to avoid many background requests.
      if (bookId.isEmpty) {
        final searchUri = proxyEndpoint('/search');
        if (searchUri == null) {
          throw const FormatException('API ReelShort não configurada');
        }
        final response = await request(searchUri.replace(queryParameters: {
          'keywords': novel.title,
        }));
        if (response is! Map || response['results'] is! List) {
          throw const FormatException('API não retornou resultado da busca');
        }
        for (final candidate in response['results'] as List) {
          if (candidate is! Map) continue;
          if ((candidate['filtered_title'] ?? '').toString() == novel.slug) {
            bookId = (candidate['book_id'] ?? '').toString();
            break;
          }
        }
        if (bookId.isEmpty) {
          throw const FormatException('Identificador da novelinha não encontrado');
        }
      }
      final uri = proxyEndpoint('/episodes/' + Uri.encodeComponent(bookId));
      if (uri == null) {
        throw const FormatException('Configure a API ReelShort nas opções');
      }
      final response = await request(uri.replace(queryParameters: {
        'filtered_title': novel.slug,
      }));
      if (response is! Map || response['episodes'] is! List) {
        throw const FormatException('Episódios não encontrados na resposta');
      }
      final episodes = <Episode>[];
      for (final item in response['episodes'] as List) {
        if (item is! Map) continue;
        final number = int.tryParse((item['episode'] ?? '').toString());
        if (number != null) {
          episodes.add(Episode(
            number,
            'Episódio $number',
            '',
            chapterId: (item['chapter_id'] ?? '').toString(),
            isFree: item['free'] == true,
          ));
        }
      }
      episodes.sort((a, b) => a.number.compareTo(b.number));
      return Novel(bookId, novel.title, novel.synopsis, novel.genre,
          novel.cover, episodes,
          slug: novel.slug, fromReelShort: true);
    }

    if (novel.id.isEmpty) return novel;
    final uri = genericEndpoint(apiInfoPath);
    if (uri == null) return novel;
    final response = await request(
        uri.replace(queryParameters: {'id': novel.id}));
    dynamic node = response;
    for (var i = 0; i < 5; i++) {
      if (node is! Map) break;
      if (node['episodes'] is List || node['episode_list'] is List) {
        final items = node['episodes'] ?? node['episode_list'];
        final episodes = (items as List).whereType<Map>().map(
          (item) => Episode.fromJson(Map<String, dynamic>.from(item)),
        ).toList();
        return Novel(novel.id, novel.title, novel.synopsis,
            novel.genre, novel.cover, episodes);
      }
      dynamic next;
      for (final key in const ['data','result','info','playlet','detail']) {
        if (node[key] is Map) {
          next = node[key];
          break;
        }
      }
      if (next == null) break;
      node = next;
    }
    throw const FormatException('A API não retornou episódios');
  }
}
