import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _publishedCatalogApi = 'https://novelplay-api-ee5f.onrender.com/catalog';

class PublishedCatalogScreen extends StatefulWidget {
  final String? initialSeriesId;
  const PublishedCatalogScreen({super.key, this.initialSeriesId});
  @override
  State<PublishedCatalogScreen> createState() => _PublishedCatalogScreenState();
}

class _PublishedCatalogScreenState extends State<PublishedCatalogScreen> {
  late Future<List<Map<String, dynamic>>> _request = _load();
  bool _isAdmin = false;
  String? _adminToken;

  @override
  void initState() {
    super.initState();
    _loadAdminSession();
  }

  Future<void> _loadAdminSession() async {
    final prefs = await SharedPreferences.getInstance();
    final rawUser = prefs.getString('novelplay_auth_user');
    final token = prefs.getString('novelplay_auth_token');
    var admin = false;
    if (rawUser != null) {
      try {
        final user = jsonDecode(rawUser) as Map<String, dynamic>;
        admin = user['role'] == 'admin';
      } catch (_) {}
    }
    if (mounted) setState(() { _isAdmin = admin; _adminToken = token; });
  }

  Future<void> _deleteSeries(Map<String, dynamic> item) async {
    final id = (item['id'] ?? '').toString();
    final title = (item['title'] ?? 'esta publicação').toString();
    if (!_isAdmin || _adminToken == null || id.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir publicação?'),
        content: Text('A novelinha "$title" e todos os episódios dela serão removidos do catálogo. Essa ação não pode ser desfeita.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final response = await http.delete(
        Uri.parse('https://novelplay-api-ee5f.onrender.com/admin/catalog/series/$id'),
        headers: {'Authorization': 'Bearer $_adminToken'},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String message = 'Não foi possível excluir a publicação (HTTP ${response.statusCode}).';
        try { message = (jsonDecode(response.body) as Map)['error']?.toString() ?? message; } catch (_) {}
        throw Exception(message);
      }
      setState(() => _request = _load());
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Publicação excluída.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao excluir: $error')));
    }
  }

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
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    leading: SizedBox(
                      width: 58,
                      height: 76,
                      child: cover.startsWith('https://')
                          ? Image.network(cover, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.movie))
                          : const Icon(Icons.movie, size: 36),
                    ),
                    title: Text((item['title'] ?? 'Novelinha').toString()),
                    subtitle: Text('${episodes.length} episódios'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isAdmin)
                          IconButton(
                            tooltip: 'Excluir publicação',
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            onPressed: () => _deleteSeries(item),
                          ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _PublishedSeriesDetails(item: item, episodes: episodes),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
}

class _PublishedSeriesDetails extends StatelessWidget {
  final Map<String, dynamic> item;
  final List<Map<String, dynamic>> episodes;

  const _PublishedSeriesDetails({required this.item, required this.episodes});

  @override
  Widget build(BuildContext context) {
    final title = (item['title'] ?? 'Novelinha').toString();
    final cover = (item['coverUrl'] ?? '').toString();
    final synopsis = (item['synopsis'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          tooltip: 'Voltar ao catálogo',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (cover.startsWith('https://'))
            Center(child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.network(cover, height: 190, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 72)),
            )),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (synopsis.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(synopsis, style: const TextStyle(height: 1.45)),
          ],
          const SizedBox(height: 22),
          Text('Episódios (${episodes.length})',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (var index = 0; index < episodes.length; index++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('${episodes[index]['number'] ?? index + 1}')),
              title: Text((episodes[index]['title'] ?? 'Episódio').toString()),
              trailing: const Icon(Icons.play_circle_outline),
              onTap: (episodes[index]['videoUrl'] ?? '').toString().startsWith('https://')
                  ? () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => _PublishedPlayer(
                        seriesTitle: title, episodes: episodes, initialIndex: index)))
                  : null,
            ),
          if (episodes.isEmpty)
            const Padding(padding: EdgeInsets.all(12),
              child: Text('Esta novelinha ainda não tem episódios.')),
        ],
      ),
    );
  }
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
    WakelockPlus.enable();
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
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
      setState(() => _showPlaybackControl = true);
    } else {
      player.play();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
    WakelockPlus.disable();
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
                                onVerticalDragEnd: (details) {
                                  final velocity = details.primaryVelocity ?? 0;
                                  if (velocity < -250) _next();
                                  if (velocity > 250) _previous();
                                },
                                onHorizontalDragEnd: (details) {
                                  final velocity = details.primaryVelocity ?? 0;
                                  if (velocity < -250) _next();
                                  if (velocity > 250) _previous();
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
