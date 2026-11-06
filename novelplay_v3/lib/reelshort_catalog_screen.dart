import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const _catalogApi = 'https://novelplay-api-ee5f.onrender.com';

class ReelShortCatalogScreen extends StatefulWidget {
  final bool isAdmin;
  const ReelShortCatalogScreen({super.key, this.isAdmin = false});
  @override
  State<ReelShortCatalogScreen> createState() => _ReelShortCatalogScreenState();
}

class _ReelShortCatalogScreenState extends State<ReelShortCatalogScreen> {
  late Future<List<Map<String, dynamic>>> _request = _load();

  Future<Map<String, dynamic>> _api(String path, {String method = 'GET', Map<String, dynamic>? body, bool authenticated = false}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (authenticated) {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('novelplay_auth_token');
      if (token == null) throw Exception('Entre novamente na sua conta.');
      headers['Authorization'] = 'Bearer $token';
    }
    final uri = Uri.parse('$_catalogApi$path');
    final response = method == 'POST'
        ? await http.post(uri, headers: headers, body: body == null ? null : jsonEncode(body))
        : await http.get(uri, headers: headers);
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) throw Exception('Resposta inválida do servidor.');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['error']?.toString() ?? 'Erro HTTP \${response.statusCode}.');
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final data = await _api('/catalog');
    return (data['series'] as List? ?? []).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  }
  void _refresh() => setState(() => _request = _load());

  Future<void> _createSeries() async {
    final title = TextEditingController(), synopsis = TextEditingController(), cover = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nova série'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Nome da série')),
          const SizedBox(height: 10),
          TextField(controller: synopsis, decoration: const InputDecoration(labelText: 'Descrição'), maxLines: 3),
          const SizedBox(height: 10),
          TextField(controller: cover, decoration: const InputDecoration(labelText: 'Link HTTPS da capa (opcional)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Criar')),
        ],
      ),
    );
    if (result != true) { title.dispose(); synopsis.dispose(); cover.dispose(); return; }
    if (title.text.trim().isEmpty) { _message('Informe o nome da série.'); title.dispose(); synopsis.dispose(); cover.dispose(); return; }
    try {
      await _api('/admin/catalog/series', method: 'POST', authenticated: true, body: {
        'title': title.text.trim(), 'synopsis': synopsis.text.trim(), 'coverUrl': cover.text.trim(),
      });
      _refresh();
      _message('Série criada.');
    } catch (e) {
      _message(e.toString().replaceFirst('Exception: ', ''));
    } finally { title.dispose(); synopsis.dispose(); cover.dispose(); }
  }

  void _message(String value) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff101018),
    appBar: AppBar(title: const Text('ReelShort'), actions: [
      if (widget.isAdmin) IconButton(tooltip: 'Adicionar série', onPressed: _createSeries, icon: const Icon(Icons.add_circle_outline)),
      IconButton(tooltip: 'Atualizar', onPressed: _refresh, icon: const Icon(Icons.refresh)),
    ]),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Não foi possível carregar o catálogo.\n\${snapshot.error}')));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final series = snapshot.data!;
        if (series.isEmpty) return Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.video_library_outlined, size: 58, color: Color(0xffff6b9d)),
          const SizedBox(height: 12),
          const Text('Nenhuma série cadastrada', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(widget.isAdmin ? 'Toque no botão + para cadastrar a primeira série e adicionar os links dos episódios.' : 'Novas séries autorizadas aparecerão aqui assim que forem cadastradas.'),
        ])));
        return RefreshIndicator(
          onRefresh: () async { _refresh(); await _request; },
          child: ListView.builder(
            padding: const EdgeInsets.all(14), itemCount: series.length,
            itemBuilder: (context, index) {
              final item = series[index];
              final episodes = item['episodes'] as List? ?? [];
              final coverUrl = (item['coverUrl'] ?? '').toString();
              return Card(
                color: const Color(0xff1b1b27), clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(10),
                  leading: SizedBox(width: 58, height: 76,
                    child: coverUrl.startsWith('https://')
                      ? Image.network(coverUrl, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie))
                      : const Icon(Icons.movie, size: 38, color: Color(0xffff6b9d))),
                  title: Text((item['title'] ?? 'Série').toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('\${episodes.length} episódios\n\${(item['synopsis'] ?? '').toString()}', maxLines: 3, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ReelShortSeriesScreen(series: item, isAdmin: widget.isAdmin, onChanged: _refresh))),
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class _ReelShortSeriesScreen extends StatefulWidget {
  final Map<String, dynamic> series;
  final bool isAdmin;
  final VoidCallback onChanged;
  const _ReelShortSeriesScreen({required this.series, required this.isAdmin, required this.onChanged});
  @override
  State<_ReelShortSeriesScreen> createState() => _ReelShortSeriesScreenState();
}

class _ReelShortSeriesScreenState extends State<_ReelShortSeriesScreen> {
  Future<void> _addEpisode() async {
    final number = TextEditingController(), title = TextEditingController(), url = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Adicionar episódio'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: number, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Número do episódio')),
          const SizedBox(height: 10),
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Título (opcional)')),
          const SizedBox(height: 10),
          TextField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Link autorizado .m3u8', hintText: 'https://...m3u8'), maxLines: 3),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Salvar episódio')),
        ],
      ),
    );
    if (accepted != true) { number.dispose(); title.dispose(); url.dispose(); return; }
    final parsedNumber = int.tryParse(number.text.trim());
    final uri = Uri.tryParse(url.text.trim());
    if (parsedNumber == null || parsedNumber < 1 || uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      _show('Informe um número válido e um link HTTPS autorizado.');
      number.dispose(); title.dispose(); url.dispose(); return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('novelplay_auth_token');
      if (token == null) throw Exception('Entre novamente na sua conta.');
      final response = await http.post(
        Uri.parse('$_catalogApi/admin/catalog/series/\${widget.series['id']}/episodes'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({
          'number': parsedNumber,
          'title': title.text.trim().isEmpty ? 'Episódio $parsedNumber' : title.text.trim(),
          'videoUrl': url.text.trim(),
        }),
      );
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data is Map ? data['error'] ?? 'Falha ao salvar.' : 'Falha ao salvar.');
      }
      setState(() {});
      widget.onChanged();
      _show('Episódio salvo no catálogo.');
    } catch (e) {
      _show(e.toString().replaceFirst('Exception: ', ''));
    } finally { number.dispose(); title.dispose(); url.dispose(); }
  }

  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final episodes = (widget.series['episodes'] as List? ?? []).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList()
      ..sort((a, b) => (a['number'] as int? ?? 0).compareTo(b['number'] as int? ?? 0));
    return Scaffold(
      backgroundColor: const Color(0xff101018),
      appBar: AppBar(title: Text((widget.series['title'] ?? 'Série').toString()), actions: [
        if (widget.isAdmin) IconButton(onPressed: _addEpisode, icon: const Icon(Icons.add), tooltip: 'Adicionar episódio'),
      ]),
      body: episodes.isEmpty
        ? Center(child: Text(widget.isAdmin ? 'Adicione o primeiro episódio pelo botão +.' : 'Ainda não há episódios cadastrados.'))
        : ListView.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final number = episode['number'] as int? ?? index + 1;
            return ListTile(
              leading: CircleAvatar(backgroundColor: const Color(0xff38202a), child: Text('$number')),
              title: Text((episode['title'] ?? 'Episódio $number').toString()),
              subtitle: const Text('Assistir no NovelPlay'),
              trailing: const Icon(Icons.play_circle_outline, color: Color(0xffff6b9d)),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _AuthorizedHlsPlayer(
                title: (episode['title'] ?? 'Episódio $number').toString(),
                url: (episode['videoUrl'] ?? '').toString(),
              ))),
            );
          },
        ),
    );
  }
}

class _AuthorizedHlsPlayer extends StatefulWidget {
  final String title, url;
  const _AuthorizedHlsPlayer({required this.title, required this.url});
  @override
  State<_AuthorizedHlsPlayer> createState() => _AuthorizedHlsPlayerState();
}

class _AuthorizedHlsPlayerState extends State<_AuthorizedHlsPlayer> {
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;
  @override
  void initState() { super.initState(); _initialize(); }

  Future<void> _initialize() async {
    try {
      final uri = Uri.parse(widget.url);
      if (uri.scheme != 'https' || uri.host.isEmpty) throw Exception('Link HTTPS inválido.');
      final player = VideoPlayerController.networkUrl(uri);
      _controller = player;
      await player.initialize();
      await player.play();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() {
        _error = 'Não foi possível abrir este link. Ele pode ter expirado ou não permitir reprodução externa.\n$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() { _controller?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: Text(widget.title)),
    body: Center(child: _loading
      ? const CircularProgressIndicator()
      : _error != null
        ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
        : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AspectRatio(
              aspectRatio: _controller!.value.aspectRatio > 0 ? _controller!.value.aspectRatio : 9 / 16,
              child: VideoPlayer(_controller!),
            ),
            VideoProgressIndicator(_controller!, allowScrubbing: true, padding: const EdgeInsets.all(14)),
            IconButton.filled(
              onPressed: () => setState(() {
                if (_controller!.value.isPlaying) { _controller!.pause(); } else { _controller!.play(); }
              }),
              icon: Icon(_controller!.value.isPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ]),
    ),
  );
}
