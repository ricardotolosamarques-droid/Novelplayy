import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
const _publishedCatalogApi = 'https://novelplay-api-ee5f.onrender.com/catalog';

class PublishedCatalogScreen extends StatefulWidget {
  const PublishedCatalogScreen({super.key});
  @override
  State<PublishedCatalogScreen> createState() => _PublishedCatalogScreenState();
}
class _PublishedCatalogScreenState extends State<PublishedCatalogScreen> {
  late Future<List<Map<String, dynamic>>> _request = _load();
  Future<List<Map<String, dynamic>>> _load() async {
    final response = await http.get(Uri.parse(_publishedCatalogApi)).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('Catálogo respondeu HTTP ${response.statusCode}.');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['series'] as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Catálogo NovelPlay'), actions: [
      IconButton(onPressed: () => setState(() => _request = _load()), icon: const Icon(Icons.refresh), tooltip: 'Atualizar'),
    ]),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Não foi possível carregar o catálogo: ${snapshot.error}')));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final series = snapshot.data!;
        if (series.isEmpty) return const Center(child: Text('Ainda não há novelinhas publicadas.'));
        return ListView.builder(
          padding: const EdgeInsets.all(14), itemCount: series.length,
          itemBuilder: (context, index) {
            final item = series[index];
            final episodes = (item['episodes'] as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
            final cover = (item['coverUrl'] ?? '').toString();
            return Card(clipBehavior: Clip.antiAlias, child: ExpansionTile(
              leading: SizedBox(width: 58, height: 76, child: cover.startsWith('https://') ? Image.network(cover, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie)) : const Icon(Icons.movie, size: 36)),
              title: Text((item['title'] ?? 'Novelinha').toString()),
              subtitle: Text('${episodes.length} episódios'),
              children: [
                if ((item['synopsis'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: Text(item['synopsis'].toString())),
                for (final episode in episodes)
                  ListTile(
                    leading: CircleAvatar(child: Text('${episode['number'] ?? '?'}')),
                    title: Text((episode['title'] ?? 'Episódio').toString()),
                    trailing: const Icon(Icons.play_circle_outline),
                    onTap: (episode['videoUrl'] ?? '').toString().startsWith('https://') ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => _PublishedPlayer(seriesTitle: (item['title'] ?? 'Novelinha').toString(), episodes: episodes, initialIndex: episodes.indexOf(episode)))) : null,
                  ),
              ],
            ));
          },
        );
      },
    ),
  );
}

class _PublishedPlayer extends StatefulWidget {
  final String seriesTitle;
  final List<Map<String, dynamic>> episodes;
  final int initialIndex;
  const _PublishedPlayer({required this.seriesTitle, required this.episodes, required this.initialIndex});
  @override
  State<_PublishedPlayer> createState() => _PublishedPlayerState();
}
class _PublishedPlayerState extends State<_PublishedPlayer> {
  late int _index = widget.initialIndex;
  VideoPlayerController? _controller;
  bool _busy = true;
  String? _error;
  @override
  void initState() { super.initState(); _open(); }
  Future<void> _open() async {
    final url = (widget.episodes[_index]['videoUrl'] ?? '').toString();
    final old = _controller;
    final player = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = player;
    setState(() { _busy = true; _error = null; });
    await old?.dispose();
    try {
      await player.initialize();
      if (!mounted || _controller != player) return;
      player.addListener(_ended);
      setState(() => _busy = false);
      await player.play();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = 'Não foi possível reproduzir este link: $e'; });
    }
  }
  void _ended() {
    final player = _controller;
    if (player != null && player.value.isInitialized && player.value.position >= player.value.duration && _index < widget.episodes.length - 1) {
      player.removeListener(_ended);
      _next();
    }
  }
  void _next() { if (_index < widget.episodes.length - 1) { setState(() => _index++); _open(); } }
  void _previous() { if (_index > 0) { setState(() => _index--); _open(); } }
  @override
  void dispose() { _controller?.removeListener(_ended); _controller?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final player = _controller;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.seriesTitle} • Episódio ${widget.episodes[_index]['number'] ?? _index + 1}')),
      backgroundColor: Colors.black,
      body: Center(child: _busy ? const CircularProgressIndicator() : _error != null
        ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center))
        : GestureDetector(
            onHorizontalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < -250) _next();
              if ((details.primaryVelocity ?? 0) > 250) _previous();
            },
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (player != null && player.value.isInitialized) AspectRatio(aspectRatio: player.value.aspectRatio > 0 ? player.value.aspectRatio : 9 / 16, child: VideoPlayer(player)),
              if (player != null && player.value.isInitialized) VideoProgressIndicator(player, allowScrubbing: true, padding: const EdgeInsets.all(14)),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(onPressed: _previous, icon: const Icon(Icons.skip_previous, size: 36)),
                IconButton.filled(onPressed: () => setState(() { if (player!.value.isPlaying) { player.pause(); } else { player.play(); } }), icon: Icon(player?.value.isPlaying == true ? Icons.pause : Icons.play_arrow, size: 32)),
                IconButton(onPressed: _next, icon: const Icon(Icons.skip_next, size: 36)),
              ]),
            ]),
          )),
    );
  }
}
