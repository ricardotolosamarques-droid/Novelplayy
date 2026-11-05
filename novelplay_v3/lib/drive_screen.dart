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
  String _searchQuery = '';
  final Set<String> _favoriteIds = <String>{};
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
        backgroundColor: const Color(0xff101018),
        appBar: AppBar(
          backgroundColor: const Color(0xff101018),
          elevation: 0,
          leading: _selectedFolderId == null
              ? Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Container(
                    decoration: BoxDecoration(color: const Color(0xff292033), borderRadius: BorderRadius.circular(13)),
                    child: const Icon(Icons.movie_filter_rounded, color: Color(0xffff6b9d)),
                  ),
                )
              : IconButton(
                  tooltip: 'Voltar às séries',
                  onPressed: _goBackToSeries,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
          title: Text(_selectedSeriesName ?? 'NOVELINHA', style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.4)),
          actions: [
            IconButton(tooltip: 'Atualizar', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
            const SizedBox(width: 8),
          ],
        ),
        body: FutureBuilder<List<dynamic>>(
          future: _content,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: Color(0xffff6b9d)));
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
              final allSeries = items.cast<DriveSeries>();
              final series = allSeries.where((item) => item.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
              if (allSeries.isEmpty) {
                return _DriveMessage(
                  title: 'Nenhuma série encontrada',
                  message: 'Crie uma pasta para cada novelinha dentro da pasta principal do Google Drive. O nome da pasta será o nome da série.',
                  onRetry: _refresh,
                );
              }
              return RefreshIndicator(
                color: const Color(0xffff6b9d),
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xff702b59), Color(0xff30203f), Color(0xff1b1b2b)],
                        ),
                      ),
                      child: Stack(
                        children: [
                          const Positioned(right: 0, top: 0, child: Icon(Icons.auto_awesome_rounded, size: 54, color: Color(0x55ffffff))),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(color: const Color(0x33ffffff), borderRadius: BorderRadius.circular(30)),
                                child: const Text('SEU UNIVERSO DE HISTÓRIAS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                              ),
                              const SizedBox(height: 18),
                              const Text('Qual vai ser\n a próxima história?', style: TextStyle(fontSize: 27, height: 1.12, fontWeight: FontWeight.w900)),
                              const SizedBox(height: 12),
                              Text('\${series.length} séries disponíveis', style: const TextStyle(color: Color(0xffe5cbd9), fontSize: 13)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    TextField(
                      onChanged: (value) => setState(() => _searchQuery = value),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Buscar novelinhas...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(Icons.search_rounded, color: Color(0xffff8bb3)),
                        filled: true,
                        fillColor: const Color(0xff1c1c29),
                        contentPadding: const EdgeInsets.symmetric(vertical: 15),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        const Expanded(child: Text('Explorar séries', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
                        Text('\${series.length} títulos', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: series.length,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.82,
                      ),
                      itemBuilder: (context, index) {
                        final item = series[index];
                        const palettes = [
                          [Color(0xff74365f), Color(0xff30213f)],
                          [Color(0xff344d70), Color(0xff1b263c)],
                          [Color(0xff80502f), Color(0xff392638)],
                          [Color(0xff315c58), Color(0xff1c303b)],
                        ];
                        final colors = palettes[index % palettes.length];
                        return Material(
                          color: const Color(0xff1b1b27),
                          borderRadius: BorderRadius.circular(20),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _openSeries(item),
                            child: Ink(
                              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors)),
                              child: Stack(
                                children: [
                                  const Positioned(right: -12, top: 10, child: Icon(Icons.movie_creation_outlined, size: 94, color: Color(0x22ffffff))),
                                  Positioned(
                                    right: 10,
                                    top: 10,
                                    child: IconButton.filledTonal(
                                      visualDensity: VisualDensity.compact,
                                      style: IconButton.styleFrom(backgroundColor: const Color(0x33000000)),
                                      onPressed: () => setState(() {
                                        if (!_favoriteIds.add(item.id)) _favoriteIds.remove(item.id);
                                      }),
                                      icon: Icon(_favoriteIds.contains(item.id) ? Icons.favorite : Icons.favorite_border, color: const Color(0xffff8bb3), size: 19),
                                    ),
                                  ),
                                  Positioned(
                                    left: 14,
                                    right: 14,
                                    bottom: 15,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(9),
                                          decoration: BoxDecoration(color: const Color(0x33ffffff), borderRadius: BorderRadius.circular(12)),
                                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                                        ),
                                        const SizedBox(height: 13),
                                        Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.1)),
                                        const SizedBox(height: 5),
                                        const Text('TOQUE PARA ASSISTIR', style: TextStyle(fontSize: 9, letterSpacing: 1, color: Color(0xffe6dbe5))),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            }

            final episodes = items.cast<DriveEpisode>();
            if (episodes.isEmpty) {
              return _DriveMessage(
                title: 'Nenhum episódio encontrado',
                message: 'Coloque os vídeos dentro da pasta "\${_selectedSeriesName ?? "da série"}" e atualize a lista.',
                onRetry: _refresh,
              );
            }
            return RefreshIndicator(
              color: const Color(0xffff6b9d),
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), gradient: const LinearGradient(colors: [Color(0xff702b59), Color(0xff30203f)])),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SUA SÉRIE', style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.bold, color: Color(0xfff2c9dc))),
                        const SizedBox(height: 8),
                        Text(_selectedSeriesName ?? 'Episódios', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 5),
                        Text('\${episodes.length} episódios • escolha onde continuar', style: const TextStyle(color: Color(0xffe5cbd9), fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('Lista de episódios', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  for (var i = 0; i < episodes.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: const Color(0xff1c1c29),
                        borderRadius: BorderRadius.circular(17),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(17),
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _DrivePlayerPage(episodes: episodes, initialIndex: i))),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                            child: Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(color: const Color(0xff43243c), borderRadius: BorderRadius.circular(14)),
                                  child: Text('\${episodes[i].number == 0 ? i + 1 : episodes[i].number}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Color(0xffff8bb3))),
                                ),
                                const SizedBox(width: 13),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(episodes[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                      const SizedBox(height: 4),
                                      const Text('Pronto para assistir', style: TextStyle(color: Colors.white54, fontSize: 11)),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.play_circle_fill_rounded, color: Color(0xffff6b9d), size: 30),
                              ],
                            ),
                          ),
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
