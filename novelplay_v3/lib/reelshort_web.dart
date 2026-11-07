import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'catalog.dart';

const String _catalogApi = 'https://novelplay-api-ee5f.onrender.com';

class ReelShortPage extends StatefulWidget {
  final Uri url;
  final String title;
  const ReelShortPage({super.key, required this.url, required this.title});
  static Uri get homeUrl => Uri.https('www.reelshort.com', '/');
  static bool _isAllowedHost(String host) => host == 'reelshort.com' || host.endsWith('.reelshort.com');
  static Uri? movieUrl(String slug, String id) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(slug) || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) return null;
    return Uri.https('www.reelshort.com', '/id/movie/$slug-$id');
  }
  @override
  State<ReelShortPage> createState() => _ReelShortPageState();
}

class _ReelShortPageState extends State<ReelShortPage> {
  late final WebViewController controller;
  int progress = 0;
  String? error;
  Map<String, dynamic> detectedPage = {};
  bool importing = false;

  static const String _metadataScript = r'''
    (function () {
      function meta(key, attr) {
        var n = document.querySelector('meta[' + attr + '="' + key + '"]');
        return n ? (n.content || '').trim() : '';
      }
      function report() {
        try {
          NovelPlayCatalog.postMessage(JSON.stringify({
            url: location.href,
            title: meta('og:title', 'property') || meta('twitter:title', 'name') ||
              document.querySelector('h1')?.innerText?.trim() || document.title || '',
            cover: meta('og:image', 'property') || meta('twitter:image', 'name') || '',
            synopsis: meta('og:description', 'property') || meta('description', 'name') || ''
          }));
        } catch (_) {}
      }
      report();
      if (!window.__novelPlayCatalogObserver) {
        window.__novelPlayCatalogObserver = true;
        var previous = location.href;
        window.setInterval(function () {
          if (previous !== location.href) { previous = location.href; report(); }
        }, 1200);
      }
    })();
  ''';

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('NovelPlayCatalog', onMessageReceived: (message) {
        try {
          final value = jsonDecode(message.message);
          if (value is Map && mounted) setState(() => detectedPage = Map<String, dynamic>.from(value));
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) { if (mounted) setState(() => progress = value); },
        onPageStarted: (_) { if (mounted) setState(() { error = null; detectedPage = {}; }); },
        onPageFinished: (_) async { try { await controller.runJavaScript(_metadataScript); } catch (_) {} },
        onWebResourceError: (failure) {
          if (failure.isForMainFrame == true && mounted) setState(() => error = failure.description);
        },
        onNavigationRequest: (request) {
          final next = Uri.tryParse(request.url);
          if (next == null) return NavigationDecision.prevent;
          if (next.scheme == 'about' && next.path == 'blank') return NavigationDecision.navigate;
          if (next.scheme != 'https' || !ReelShortPage._isAllowedHost(next.host)) return NavigationDecision.prevent;
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.url);
  }

  Map<String, String>? _identity(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || !ReelShortPage._isAllowedHost(uri.host)) return null;
    final path = uri.path;

    // Episode URL: /episodes/episode-N-title-BOOK_ID-EPISODE_ID
    final episodeMatch = RegExp(r'^/episodes/episode-\d+-(.+)-([a-fA-F0-9]{24})-([A-Za-z0-9_]+).firstMatch(path);
    if (episodeMatch != null) {
      return {
        'slug': episodeMatch.group(1)!,
        'id': episodeMatch.group(2)!,
        'episodeId': episodeMatch.group(3)!,
        'url': uri.toString(),
      };
    }

    if (!(path.startsWith('/movie/') || path.startsWith('/id/movie/') ||
        RegExp(r'^/[a-z]{2}/full-episodes/').hasMatch(path))) return null;
    var part = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (part.toLowerCase().endsWith('.html')) part = part.substring(0, part.length - 5);
    final match = RegExp(r'^(.+)-([a-fA-F0-9]{24})$').firstMatch(part);
    if (match == null) return null;
    return {'slug': match.group(1)!, 'id': match.group(2)!, 'url': uri.toString()};
  }

  Future<Map<String, dynamic>> _fetchSeries() async {
    final currentUrl = (detectedPage['url'] ?? await controller.currentUrl() ?? widget.url.toString()).toString();
    final identity = _identity(currentUrl);
    if (identity == null) throw Exception('Abra a página de uma novelinha no ReelShort para detectar a série.');
    final slug = identity['slug']!, id = identity['id']!;
    final searchUri = Sources.proxyEndpoint('/search')!.replace(queryParameters: {'keywords': slug.replaceAll('-', ' ')});
    final search = await Sources.request(searchUri);
    Map<String, dynamic> book = {
      'book_id': id,
      'book_title': (detectedPage['title'] ?? slug.replaceAll('-', ' ')).toString(),
      'book_pic': (detectedPage['cover'] ?? '').toString(),
      'special_desc': (detectedPage['synopsis'] ?? '').toString(),
    };
    if (search is Map && search['results'] is List) {
      for (final row in search['results'] as List) {
        if (row is Map && (row['book_id'] ?? '').toString() == id) {
          book = Map<String, dynamic>.from(row);
          break;
        }
      }
    }
    final episodesUri = Sources.proxyEndpoint('/episodes/' + Uri.encodeComponent(id))!
      .replace(queryParameters: {'filtered_title': slug});
    final response = await Sources.request(episodesUri);
    if (response is! Map || response['episodes'] is! List) throw Exception('Não foi possível obter os episódios.');
    final sourceBook = response['book'];
    if (sourceBook is Map) {
      for (final key in ['book_title', 'book_pic', 'special_desc']) {
        if ((sourceBook[key] ?? '').toString().trim().isNotEmpty) book[key] = sourceBook[key];
      }
    }
    if ((book['book_title'] ?? '').toString().trim().isEmpty) book['book_title'] = detectedPage['title'] ?? slug.replaceAll('-', ' ');
    if ((book['book_pic'] ?? '').toString().trim().isEmpty) book['book_pic'] = detectedPage['cover'] ?? '';
    final episodes = <Map<String, dynamic>>[];
    for (final row in response['episodes'] as List) {
      if (row is! Map) continue;
      final number = int.tryParse((row['episode'] ?? '').toString());
      if (number == null || number < 1) continue;
      episodes.add({
        'number': number,
        'title': 'Episódio $number',
        'sourceEpisodeId': (row['chapter_id'] ?? '').toString(),
        'isFree': row['free'] == true ? true : (row['free'] == false ? false : null),
        'officialUrl': identity['url'],
      });
    }
    episodes.sort((a, b) => (a['number'] as int).compareTo(b['number'] as int));
    if (episodes.isEmpty) throw Exception('Nenhum episódio foi encontrado.');
    return {
      'title': (book['book_title'] ?? 'Novelinha').toString(),
      'coverUrl': (book['book_pic'] ?? '').toString(),
      'synopsis': (book['special_desc'] ?? '').toString(),
      'sourceBookId': id,
      'sourceFilteredTitle': slug,
      'sourceUrl': identity['url'],
      'episodes': episodes,
    };
  }

  Future<void> _importSeries() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      final data = await _fetchSeries();
      if (!mounted) return;
      final episodes = data['episodes'] as List;
      final freeCount = episodes.where((e) => e['isFree'] == true).length;
      final lockedCount = episodes.where((e) => e['isFree'] == false).length;
      final cover = (data['coverUrl'] ?? '').toString();
      final title = (data['title'] ?? 'Novelinha').toString();
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Série identificada'),
          content: SizedBox(width: 350, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (cover.startsWith('https://'))
                ClipRRect(borderRadius: BorderRadius.circular(10),
                  child: Image.network(cover, height: 170, width: 120, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 64)))
              else const Icon(Icons.movie, size: 64, color: Color(0xffff6b9d)),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 8),
              Text(episodes.length.toString() + ' episódios encontrados'),
              Text(freeCount.toString() + ' liberados • ' + lockedCount.toString() + ' bloqueados',
                style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 10),
              const Text('Os episódios bloqueados aparecem no catálogo, mas continuam exigindo acesso na página oficial do ReelShort.',
                style: TextStyle(fontSize: 12)),
            ],
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Adicionar série')),
          ],
        ),
      );
      if (confirm != true) return;
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('novelplay_auth_token');
      if (token == null) throw Exception('Entre na conta de administrador para adicionar séries.');
      final payload = <String, dynamic>{...data, 'authorizedPlayback': false};
      final resultResponse = await http.post(
        Uri.parse('$_catalogApi/admin/catalog/import'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 30));
      final result = jsonDecode(utf8.decode(resultResponse.bodyBytes));
      if (resultResponse.statusCode < 200 || resultResponse.statusCode >= 300) {
        throw Exception(result is Map ? result['error']?.toString() ?? 'Falha ao importar a série.' : 'Falha ao importar a série.');
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“' + title + '” adicionada ao NovelPlay com ' + episodes.length.toString() + ' episódios.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = (detectedPage['title'] ?? '').toString().trim();
    final cover = (detectedPage['cover'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(tooltip: 'Adicionar série detectada', onPressed: importing ? null : _importSeries,
          icon: importing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.library_add_outlined)),
        IconButton(tooltip: 'Copiar link oficial', onPressed: () async {
          final value = await controller.currentUrl();
          await Clipboard.setData(ClipboardData(text: value ?? widget.url.toString()));
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link oficial copiado.')));
        }, icon: const Icon(Icons.copy)),
        IconButton(tooltip: 'Recarregar página', onPressed: () => controller.reload(), icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        if (title.isNotEmpty) Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            if (cover.startsWith('https://')) ClipRRect(borderRadius: BorderRadius.circular(6),
              child: Image.network(cover, width: 34, height: 46, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.movie))),
            const SizedBox(width: 9),
            Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70))),
            const Text('Detectado', style: TextStyle(fontSize: 10, color: Color(0xffff6b9d))),
          ]),
        ),
        if (progress < 100) LinearProgressIndicator(value: progress / 100),
        Expanded(child: error == null ? WebViewWidget(controller: controller) :
          Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('A página não carregou: $error', textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton(onPressed: () => controller.loadRequest(widget.url), child: const Text('Tentar novamente')),
          ])))),
      ]),
    );
  }
}
).firstMatch(path);
    if (episodeMatch != null) {
      return {
        'slug': episodeMatch.group(1)!,
        'id': episodeMatch.group(2)!,
        'episodeId': episodeMatch.group(3)!,
        'url': uri.toString(),
      };
    }

    if (!(path.startsWith('/movie/') || path.startsWith('/id/movie/') ||
        RegExp(r'^/[a-z]{2}/full-episodes/').hasMatch(path))) return null;
    var part = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (part.toLowerCase().endsWith('.html')) part = part.substring(0, part.length - 5);
    final match = RegExp(r'^(.+)-([a-fA-F0-9]{24})$').firstMatch(part);
    if (match == null) return null;
    return {'slug': match.group(1)!, 'id': match.group(2)!, 'url': uri.toString()};
  }

  Future<Map<String, dynamic>> _fetchSeries() async {
    final currentUrl = (detectedPage['url'] ?? await controller.currentUrl() ?? widget.url.toString()).toString();
    final identity = _identity(currentUrl);
    if (identity == null) throw Exception('Abra a página de uma novelinha no ReelShort para detectar a série.');
    final slug = identity['slug']!, id = identity['id']!;
    final searchUri = Sources.proxyEndpoint('/search')!.replace(queryParameters: {'keywords': slug.replaceAll('-', ' ')});
    final search = await Sources.request(searchUri);
    Map<String, dynamic> book = {
      'book_id': id,
      'book_title': (detectedPage['title'] ?? slug.replaceAll('-', ' ')).toString(),
      'book_pic': (detectedPage['cover'] ?? '').toString(),
      'special_desc': (detectedPage['synopsis'] ?? '').toString(),
    };
    if (search is Map && search['results'] is List) {
      for (final row in search['results'] as List) {
        if (row is Map && (row['book_id'] ?? '').toString() == id) {
          book = Map<String, dynamic>.from(row);
          break;
        }
      }
    }
    final episodesUri = Sources.proxyEndpoint('/episodes/' + Uri.encodeComponent(id))!
      .replace(queryParameters: {'filtered_title': slug});
    final response = await Sources.request(episodesUri);
    if (response is! Map || response['episodes'] is! List) throw Exception('Não foi possível obter os episódios.');
    final sourceBook = response['book'];
    if (sourceBook is Map) {
      for (final key in ['book_title', 'book_pic', 'special_desc']) {
        if ((sourceBook[key] ?? '').toString().trim().isNotEmpty) book[key] = sourceBook[key];
      }
    }
    if ((book['book_title'] ?? '').toString().trim().isEmpty) book['book_title'] = detectedPage['title'] ?? slug.replaceAll('-', ' ');
    if ((book['book_pic'] ?? '').toString().trim().isEmpty) book['book_pic'] = detectedPage['cover'] ?? '';
    final episodes = <Map<String, dynamic>>[];
    for (final row in response['episodes'] as List) {
      if (row is! Map) continue;
      final number = int.tryParse((row['episode'] ?? '').toString());
      if (number == null || number < 1) continue;
      episodes.add({
        'number': number,
        'title': 'Episódio $number',
        'sourceEpisodeId': (row['chapter_id'] ?? '').toString(),
        'isFree': row['free'] == true ? true : (row['free'] == false ? false : null),
        'officialUrl': identity['url'],
      });
    }
    episodes.sort((a, b) => (a['number'] as int).compareTo(b['number'] as int));
    if (episodes.isEmpty) throw Exception('Nenhum episódio foi encontrado.');
    return {
      'title': (book['book_title'] ?? 'Novelinha').toString(),
      'coverUrl': (book['book_pic'] ?? '').toString(),
      'synopsis': (book['special_desc'] ?? '').toString(),
      'sourceBookId': id,
      'sourceFilteredTitle': slug,
      'sourceUrl': identity['url'],
      'episodes': episodes,
    };
  }

  Future<void> _importSeries() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      final data = await _fetchSeries();
      if (!mounted) return;
      final episodes = data['episodes'] as List;
      final freeCount = episodes.where((e) => e['isFree'] == true).length;
      final lockedCount = episodes.where((e) => e['isFree'] == false).length;
      final cover = (data['coverUrl'] ?? '').toString();
      final title = (data['title'] ?? 'Novelinha').toString();
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Série identificada'),
          content: SizedBox(width: 350, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (cover.startsWith('https://'))
                ClipRRect(borderRadius: BorderRadius.circular(10),
                  child: Image.network(cover, height: 170, width: 120, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 64)))
              else const Icon(Icons.movie, size: 64, color: Color(0xffff6b9d)),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 8),
              Text(episodes.length.toString() + ' episódios encontrados'),
              Text(freeCount.toString() + ' liberados • ' + lockedCount.toString() + ' bloqueados',
                style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 10),
              const Text('Os episódios bloqueados aparecem no catálogo, mas continuam exigindo acesso na página oficial do ReelShort.',
                style: TextStyle(fontSize: 12)),
            ],
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Adicionar série')),
          ],
        ),
      );
      if (confirm != true) return;
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('novelplay_auth_token');
      if (token == null) throw Exception('Entre na conta de administrador para adicionar séries.');
      final payload = <String, dynamic>{...data, 'authorizedPlayback': false};
      final resultResponse = await http.post(
        Uri.parse('$_catalogApi/admin/catalog/import'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 30));
      final result = jsonDecode(utf8.decode(resultResponse.bodyBytes));
      if (resultResponse.statusCode < 200 || resultResponse.statusCode >= 300) {
        throw Exception(result is Map ? result['error']?.toString() ?? 'Falha ao importar a série.' : 'Falha ao importar a série.');
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“' + title + '” adicionada ao NovelPlay com ' + episodes.length.toString() + ' episódios.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = (detectedPage['title'] ?? '').toString().trim();
    final cover = (detectedPage['cover'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(tooltip: 'Adicionar série detectada', onPressed: importing ? null : _importSeries,
          icon: importing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.library_add_outlined)),
        IconButton(tooltip: 'Copiar link oficial', onPressed: () async {
          final value = await controller.currentUrl();
          await Clipboard.setData(ClipboardData(text: value ?? widget.url.toString()));
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link oficial copiado.')));
        }, icon: const Icon(Icons.copy)),
        IconButton(tooltip: 'Recarregar página', onPressed: () => controller.reload(), icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        if (title.isNotEmpty) Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            if (cover.startsWith('https://')) ClipRRect(borderRadius: BorderRadius.circular(6),
              child: Image.network(cover, width: 34, height: 46, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.movie))),
            const SizedBox(width: 9),
            Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70))),
            const Text('Detectado', style: TextStyle(fontSize: 10, color: Color(0xffff6b9d))),
          ]),
        ),
        if (progress < 100) LinearProgressIndicator(value: progress / 100),
        Expanded(child: error == null ? WebViewWidget(controller: controller) :
          Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('A página não carregou: $error', textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton(onPressed: () => controller.loadRequest(widget.url), child: const Text('Tentar novamente')),
          ])))),
      ]),
    );
  }
}
