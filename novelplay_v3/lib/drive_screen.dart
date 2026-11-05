import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

const _folderId = '1O28a3-3bmKkVj_3dS9HlWX0Owyn3eFts';
const _apiKey = String.fromEnvironment('DRIVE_API_KEY');

class DriveSeries {
  const DriveSeries(this.id, this.name);
  final String id;
  final String name;
}

class DriveEpisode {
  const DriveEpisode(this.id, this.name, this.mimeType);
  final String id;
  final String name;
  final String mimeType;

  int get number {
    final match = RegExp(r'\d+').firstMatch(name);
    return match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
  }

  Uri get mediaUri => Uri.https(
        'www.googleapis.com',
        '/drive/v3/files/$id',
        {'alt': 'media', 'key': _apiKey},
      );
}

class DriveNovelScreen extends StatefulWidget {
  const DriveNovelScreen({super.key});

  @override
  State<DriveNovelScreen> createState() => _DriveNovelScreenState();
}

class _DriveNovelScreenState extends State<DriveNovelScreen> {
  String? _selectedFolderId;
  String? _selectedSeriesName;
  late Future<List<dynamic>> _content = _loadSeries();

  Future<List<Map<String, dynamic>>> _listChildren(String parentId) async {
    final allFiles = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final params = <String, String>{
        'q': "'$parentId' in parents and trashed = false",
        'key': _apiKey,
        'pageSize': '1000',
        'orderBy': 'name',
        'fields': 'files(id,name,mimeType),nextPageToken',
      };
      if (pageToken != null) params['pageToken'] = pageToken;
      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', params);
      final response = await http.get(uri).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception('Google Drive HTTP ${response.statusCode}: ${response.body}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      allFiles.addAll((data['files'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>());
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);
    return allFiles;
  }

  Future<List<DriveSeries>> _loadSeries() async {
    if (_apiKey.isEmpty) {
      throw Exception('A chave DRIVE_API_KEY ainda não foi configurada na compilação. Veja as instruções no README.');
    }
    final files = await _listChildren(_folderId);
    final folders = files
        .where((file) => file['mimeType'] == 'application/vnd.google-apps.folder')
        .map((file) => DriveSeries(file['id'] as String, (file['name'] as String?) ?? 'Série sem nome'))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return folders;
  }

  Future<List<DriveEpisode>> _loadEpisodes(String folderId) async {
    final files = await _listChildren(folderId);
    final episodes = files
        .where((file) => (file['mimeType'] as String? ?? '').startsWith('video/'))
        .map((file) => DriveEpisode(
              file['id'] as String,
              (file['name'] as String?) ?? 'Episódio',
              (file['mimeType'] as String?) ?? '',
            ))
        .toList();
    episodes.sort((a, b) {
      final byNumber = a.number.compareTo(b.number);
      return byNumber != 0 ? byNumber : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return episodes;
  }

  void _openSeries(DriveSeries series) {
    setState(() {
      _selectedFolderId = series.id;
      _selectedSeriesName = series.name;
      _content = _loadEpisodes(series.id);
    });
  }

  void _goBackToSeries() {
    setState(() {
      _selectedFolderId = null;
      _selectedSeriesName = null;
      _content = _loadSeries();
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _content = _selectedFolderId == null ? _loadSeries() : _loadEpisodes(_selectedFolderId!);
    });
    try {
      await _content;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: _selectedFolderId == null
              ? null
              : IconButton(
                  tooltip: 'Voltar às séries',
                  onPressed: _goBackToSeries,
                  icon: const Icon(Icons.arrow_back),
                ),
          title: Text(_selectedSeriesName ?? 'Minhas novelinhas'),
          actions: [
            IconButton(tooltip: 'Atualizar Google Drive', onPressed: _refresh, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: FutureBuilder<List<dynamic>>(
          future: _content,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _DriveMessage(
                title: 'Não foi possível acessar o Google Drive',
                message: snapshot.error.toString().replaceFirst('Exception: ', ''),
                onRetry: _refresh,
              );
            }
            final items = snapshot.data ?? [];
            if (_selectedFolderId == null) {
              final series = items.cast<DriveSeries>();
              if (series.isEmpty) {
                return _DriveMessage(
                  title: 'Nenhuma série encontrada',
                  message: 'Crie uma pasta para cada novelinha dentro da pasta principal do Google Drive. O nome da pasta será o nome da série.',
                  onRetry: _refresh,
                );
              }
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(colors: [Color(0xff8d2856), Color(0xff392044)]),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('GOOGLE DRIVE', style: TextStyle(letterSpacing: 1.4)),
                          const SizedBox(height: 8),
                          const Text('Minhas novelinhas', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
                          Text('${series.length} séries encontradas'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final seriesItem in series)
                      Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.video_library)),
                          title: Text(seriesItem.name),
                          subtitle: const Text('Abrir episódios'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openSeries(seriesItem),
                        ),
                      ),
                  ],
                ),
              );
            }

            final episodes = items.cast<DriveEpisode>();
            if (episodes.isEmpty) {
              return _DriveMessage(
                title: 'Nenhum episódio encontrado',
                message: 'Coloque os vídeos dentro da pasta "${_selectedSeriesName ?? "da série"}" e atualize a lista.',
                onRetry: _refresh,
              );
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: const LinearGradient(colors: [Color(0xff8d2856), Color(0xff392044)]),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SÉRIE', style: TextStyle(letterSpacing: 1.4)),
                        const SizedBox(height: 8),
                        Text(_selectedSeriesName ?? 'Episódios', style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
                        Text('${episodes.length} episódios encontrados'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < episodes.length; i++)
                    Card(
                      child: ListTile(
                        leading: CircleAvatar(child: Text('${episodes[i].number == 0 ? i + 1 : episodes[i].number}')),
                        title: Text(episodes[i].name),
                        subtitle: const Text('Assistir'),
                        trailing: const Icon(Icons.play_circle_outline),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => _DrivePlayerPage(episodes: episodes, initialIndex: i)),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      );
}

class _DriveMessage extends StatelessWidget {
  const _DriveMessage({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Tentar novamente')),
            ],
          ),
        ),
      );
}

class _DrivePlayerPage extends StatefulWidget {
  const _DrivePlayerPage({required this.episodes, required this.initialIndex});
  final List<DriveEpisode> episodes;
  final int initialIndex;

  @override
  State<_DrivePlayerPage> createState() => _DrivePlayerPageState();
}

class _DrivePlayerPageState extends State<_DrivePlayerPage> {
  late final PageController _pageController;
  late int _index;
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    _initialize();
  }

  Future<void> _initialize() async {
    final previous = _controller;
    _controller = null;
    await previous?.dispose();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final player = VideoPlayerController.networkUrl(widget.episodes[_index].mediaUri);
      _controller = player;
      await player.initialize();
      player.addListener(_onVideoChanged);
      await player.play();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'O Google Drive não liberou a reprodução direta deste arquivo. Verifique se ele está público e se a API permite download. Detalhe: $e';
        });
      }
    }
  }

  void _swipeToEpisode(bool next) {
    final target = _index + (next ? 1 : -1);
    if (target < 0 || target >= widget.episodes.length) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  void _onVideoChanged() {
    final player = _controller;
    if (player == null || !player.value.isInitialized) return;
    if (player.value.duration > Duration.zero &&
        player.value.position >= player.value.duration &&
        !player.value.isPlaying &&
        _index < widget.episodes.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoChanged);
    _controller?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.episodes.length,
              onPageChanged: (value) {
                setState(() => _index = value);
                _initialize();
              },
              itemBuilder: (_, __) => const ColoredBox(color: Colors.black),
            ),
            // Captura explicitamente o gesto vertical. O PageView fica
            // programático para evitar disputa de gestos com o player de vídeo.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -250) {
                    _swipeToEpisode(true);
                  } else if (velocity > 250) {
                    _swipeToEpisode(false);
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
              )
            else if (_controller != null && _controller!.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  // O vídeo não deve capturar os gestos: o PageView vertical,
                  // que fica por trás, precisa receber o swipe para trocar de episódio.
                  child: IgnorePointer(
                    child: VideoPlayer(_controller!),
                  ),
                ),
              ),
            SafeArea(
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      widget.episodes[_index].name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      final player = _controller;
                      if (player == null) return;
                      player.value.isPlaying ? player.pause() : player.play();
                      setState(() {});
                    },
                    icon: Icon(
                      (_controller?.value.isPlaying ?? false) ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            if (_controller != null && _controller!.value.isInitialized)
              Positioned(
                left: 14,
                right: 14,
                bottom: 24,
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(playedColor: Color(0xffff6da8)),
                ),
              ),
          ],
        ),
      );
}
