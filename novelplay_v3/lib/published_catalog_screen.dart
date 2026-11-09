import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

const _publishedCatalogApi = 'https://novelplay-api-ee5f.onrender.com/catalog';

class PublishedCatalogScreen extends StatefulWidget {
  final String? initialSeriesId;
  const PublishedCatalogScreen({super.key, this.initialSeriesId});
  @override
  State<PublishedCatalogScreen> createState() => _PublishedCatalogScreenState();
}

class _PublishedCatalogScreenState extends State<PublishedCatalogScreen> {
  late Future<List<Map<String, dynamic>>> _request = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final response = await http.get(Uri.parse(_publishedCatalogApi)).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('Catálogo respondeu HTTP ${response.statusCode}.');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['series'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Catálogo NovelPlay'),
          actions: [
            IconButton(
              onPressed: () => setState(() => _request = _load()),
              icon: const Icon(Icons.refresh),
              tooltip: 'Atualizar',
            ),
          ],
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _request,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Não foi possível carregar o catálogo: ${snapshot.error}'),
                ),
              );
            }
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final series = snapshot.data!;
            if (series.isEmpty) return const Center(child: Text('Ainda não há novelinhas publicadas.'));
            return ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: series.length,
              itemBuilder: (context, index) {
                final item = series[index];
                final episodes = (item['episodes'] as List? ?? const [])
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .toList();
                final cover = (item['coverUrl'] ?? '').toString();
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    initiallyExpanded: widget.initialSeriesId != null &&
                        (item['id'] ?? '').toString() == widget.initialSeriesId,
                    leading: SizedBox(
                      width: 58,
                      height: 76,
                      child: cover.startsWith('https://')
                          ? Image.network(
                              cover,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.movie),
                            )
                          : const Icon(Icons.movie, size: 36),
                    ),
                    title: Text((item['title'] ?? 'Novelinha').toString()),
                    subtitle: Text('${episodes.length} episódios'),
                    children: [
                      if ((item['synopsis'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: Text(item['synopsis'].toString()),
                        ),
                      for (final episode in episodes)
                        ListTile(
                          leading: CircleAvatar(child: Text('${episode['number'] ?? '?'}')),
                          title: Text((episode['title'] ?? 'Episódio').toString()),
                          trailing: const Icon(Icons.play_circle_outline),
                          onTap: (episode['videoUrl'] ?? '').toString().startsWith('https://')
                              ? () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => _PublishedPlayer(
                                        seriesTitle: (item['title'] ?? 'Novelinha').toString(),
                                        episodes: episodes,
                                        initialIndex: episodes.indexOf(episode),
                                      ),
                                    ),
                                  )
                              : null,
                        ),
                    ],
                  ),
                );
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

  const _PublishedPlayer({
    required this.seriesTitle,
    required this.episodes,
    required this.initialIndex,
  });

  @override
  State<_PublishedPlayer> createState() => _PublishedPlayerState();
}

class _PublishedPlayerState extends State<_PublishedPlayer> {
  late int _index = widget.initialIndex;
  VideoPlayerController? _controller;
  bool _busy = true;
  bool _showPlaybackControl = true;
  Timer? _controlsTimer;
  String? _error;

  int get _episodeNumber {
    final raw = widget.episodes[_index]['number'];
    return int.tryParse(raw?.toString() ?? '') ?? _index + 1;
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final url = (widget.episodes[_index]['videoUrl'] ?? '').toString();
    final old = _controller;
    final player = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = player;
    if (mounted) setState(() {
      _busy = true;
      _error = null;
    });
    await old?.dispose();
    try {
      await player.initialize();
      if (!mounted || _controller != player) return;
      player.addListener(_ended);
      setState(() {
        _busy = false;
        _showPlaybackControl = true;
      });
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await player.play();
      _scheduleHidePlaybackControl();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Não foi possível reproduzir este link: $e';
        });
      }
    }
  }

  void _scheduleHidePlaybackControl() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted || _controller?.value.isPlaying != true) return;
      setState(() => _showPlaybackControl = false);
    });
  }

  void _togglePlayback() {
    final player = _controller;
    if (player == null) return;
    if (player.value.isPlaying) {
      _controlsTimer?.cancel();
      player.pause();
      setState(() => _showPlaybackControl = true);
    } else {
      player.play();
      setState(() => _showPlaybackControl = true);
      _scheduleHidePlaybackControl();
    }
  }

  void _showPlaybackControls() {
    if (_controller?.value.isPlaying != true) return;
    setState(() => _showPlaybackControl = true);
    _scheduleHidePlaybackControl();
  }

  void _ended() {
    final player = _controller;
    if (player != null &&
        player.value.isInitialized &&
        player.value.position >= player.value.duration &&
        _index < widget.episodes.length - 1) {
      player.removeListener(_ended);
      _next();
    }
  }

  void _next() {
    if (_index < widget.episodes.length - 1) {
      setState(() => _index++);
      _open();
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index--);
      _open();
    }
  }

  Future<void> _showEpisodes() async {
    _controlsTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.62,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Todos os episódios',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    '${widget.episodes.length} episódios',
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.18,
                ),
                itemCount: widget.episodes.length,
                itemBuilder: (context, index) {
                  final raw = widget.episodes[index]['number'];
                  final number = int.tryParse(raw?.toString() ?? '') ?? index + 1;
                  final selected = index == _index;
                  final hasUrl = (widget.episodes[index]['videoUrl'] ?? '').toString().startsWith('https://');
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: hasUrl
                        ? () {
                            Navigator.pop(sheetContext);
                            if (index != _index) {
                              setState(() => _index = index);
                              _open();
                            }
                          }
                        : null,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected ? const Color(0xFFE53935) : const Color(0xFF292929),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected ? const Color(0xFFFF7773) : Colors.white10,
                        ),
                      ),
                      child: Text(
                        'EP.$number',
                        style: TextStyle(
                          color: hasUrl ? Colors.white : Colors.white38,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted && _controller?.value.isPlaying == true) {
      _scheduleHidePlaybackControl();
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _controller?.removeListener(_ended);
    _controller?.dispose();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _controller;
    final initialized = player?.value.isInitialized == true;
    final playing = player?.value.isPlaying == true;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${widget.seriesTitle} • EP.$_episodeNumber'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _busy
                    ? const CircularProgressIndicator(color: Colors.white)
                    : _error != null
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                          )
                        : initialized
                            ? GestureDetector(
                                onHorizontalDragEnd: (details) {
                                  if ((details.primaryVelocity ?? 0) < -250) _next();
                                  if ((details.primaryVelocity ?? 0) > 250) _previous();
                                },
                                child: AspectRatio(
                                  aspectRatio: player!.value.aspectRatio > 0 ? player.value.aspectRatio : 9 / 16,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      VideoPlayer(player),
                                      Positioned.fill(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          onTap: _showPlaybackControls,
                                        ),
                                      ),
                                      if (_showPlaybackControl)
                                        Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            customBorder: const CircleBorder(),
                                            onTap: _togglePlayback,
                                            child: Container(
                                              width: 82,
                                              height: 82,
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(0.48),
                                                shape: BoxShape.circle,
                                                border: Border.all(color: Colors.white70, width: 1.5),
                                              ),
                                              child: Icon(
                                                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                                color: Colors.white,
                                                size: 56,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
              ),
            ),
            if (initialized && _error == null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
                child: VideoProgressIndicator(
                  player!,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Color(0xFFE53935),
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _showEpisodes,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white30),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.grid_view_rounded, size: 19),
                    label: Text(
                      'EP.$_episodeNumber/EP.${widget.episodes.length}',
                      style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
