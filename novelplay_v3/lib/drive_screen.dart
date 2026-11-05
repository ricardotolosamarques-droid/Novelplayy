import 'dart:async';
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
  int _tabIndex = 0;
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
        appBar: _selectedFolderId == null ? null : AppBar(
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
        bottomNavigationBar: _selectedFolderId == null
            ? BottomNavigationBar(
                currentIndex: _tabIndex,
                onTap: (index) => setState(() => _tabIndex = index),
                backgroundColor: const Color(0xff15131c),
                selectedItemColor: const Color(0xffff6b9d),
                unselectedItemColor: const Color(0xff8d8797),
                type: BottomNavigationBarType.fixed,
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Início'),
                  BottomNavigationBarItem(icon: Icon(Icons.explore_rounded), label: 'Explorar'),
                  BottomNavigationBarItem(icon: Icon(Icons.bookmark_rounded), label: 'Minha lista'),
                ],
              )
            : null,
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
              final series = allSeries.where((item) {
                final matchesSearch = item.name.toLowerCase().contains(_searchQuery.toLowerCase());
                final matchesTab = _tabIndex != 2 || _favoriteIds.contains(item.id);
                return matchesSearch && matchesTab;
              }).toList();
              if (allSeries.isEmpty) {
                return _DriveMessage(
                  title: 'Nenhuma série encontrada',
                  message: 'Crie uma pasta para cada novelinha dentro da pasta principal do Google Drive. O nome da pasta será o nome da série.',
                  onRetry: _refresh,
                );
              }
              return RefreshIndicator(
                color: const Color(0xffff5b9a),
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42, height: 42,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Color(0xffff6da8), Color(0xff9c3f83)]),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 29),
                        ),
                        const SizedBox(width: 11),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('NOVELINHA', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 2.0)),
                            Text('HISTÓRIAS QUE PRENDEM', style: TextStyle(fontSize: 8, color: Color(0xffff8db8), letterSpacing: 1.6, fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const Spacer(),
                        Container(
                          decoration: BoxDecoration(color: const Color(0xff211c2a), borderRadius: BorderRadius.circular(14)),
                          child: IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh_rounded, color: Colors.white70), tooltip: 'Atualizar'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 27),
                    const Text('SEU PRÓXIMO VÍCIO', style: TextStyle(color: Color(0xffff83b0), fontSize: 10, letterSpacing: 2.0, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    const Text('Uma história\npara maratonar.', style: TextStyle(fontSize: 31, height: 1.04, fontWeight: FontWeight.w900, letterSpacing: -0.8)),
                    const SizedBox(height: 9),
                    Text('${series.length} histórias esperando por você', style: const TextStyle(color: Color(0xffaaa4b4), fontSize: 13)),
                    if (_tabIndex != 2) const SizedBox(height: 20),
                    if (_tabIndex != 2) Container(
                      height: 174,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xff9d3d70), Color(0xff512b59), Color(0xff211c32)],
                        ),
                        boxShadow: const [BoxShadow(color: Color(0x553f1738), blurRadius: 22, offset: Offset(0, 10))],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          const Positioned(right: -8, top: -28, child: Icon(Icons.local_movies_rounded, size: 190, color: Color(0x22ffffff))),
                          Positioned(right: 18, bottom: 16, child: Transform.rotate(angle: -0.12, child: const Icon(Icons.auto_awesome, size: 68, color: Color(0x55ffffff)))),
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(color: const Color(0x33ffffff), borderRadius: BorderRadius.circular(30)),
                                  child: const Text('CATÁLOGO EXCLUSIVO', style: TextStyle(fontSize: 9, letterSpacing: 1.4, fontWeight: FontWeight.w900)),
                                ),
                                const SizedBox(height: 12),
                                const Text('Drama, romance\ne reviravoltas.', style: TextStyle(fontSize: 23, height: 1.05, fontWeight: FontWeight.w900)),
                                const SizedBox(height: 9),
                                Row(
                                  children: [
                                    const Icon(Icons.play_circle_fill_rounded, size: 17, color: Color(0xffffc4da)),
                                    const SizedBox(width: 6),
                                    Text('${series.length} títulos para descobrir', style: const TextStyle(fontSize: 11, color: Color(0xfff4dce8))),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_tabIndex != 2) const SizedBox(height: 24),
                    if (_tabIndex != 2) TextField(
                      onChanged: (value) => setState(() => _searchQuery = value),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Qual história você procura?',
                        hintStyle: const TextStyle(color: Color(0xff827c8c), fontSize: 13),
                        prefixIcon: const Icon(Icons.search_rounded, color: Color(0xffff78aa)),
                        filled: true, fillColor: const Color(0xff211e2a),
                        contentPadding: const EdgeInsets.symmetric(vertical: 17),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(17), borderSide: const BorderSide(color: Color(0xff302a39))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(17), borderSide: const BorderSide(color: Color(0xffff6b9d), width: 1.2)),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_tabIndex == 2 ? 'SUA COLEÇÃO' : _tabIndex == 1 ? 'DESCUBRA MAIS' : 'EM DESTAQUE', style: const TextStyle(color: Color(0xffff83b0), fontSize: 9, letterSpacing: 2, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 4),
                          Text(_tabIndex == 2 ? 'Minha lista' : _tabIndex == 1 ? 'Explore dramas' : 'Novelinhas para assistir', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -0.4)),
                        ])),
                        Text('${series.length} títulos', style: const TextStyle(color: Color(0xff918b9b), fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 15),
                    if (series.isEmpty)
                      Padding(padding: const EdgeInsets.all(24), child: Text(_tabIndex == 2 ? 'Sua lista está vazia. Toque no coração de uma série para salvá-la aqui.' : 'Nenhuma novelinha encontrada.', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)))
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: series.length,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2, crossAxisSpacing: 13, mainAxisSpacing: 15, childAspectRatio: 0.69,
                        ),
                        itemBuilder: (context, index) {
                          final item = series[index];
                          const palettes = [
                            [Color(0xffa84d79), Color(0xff382039)],
                            [Color(0xff426b8d), Color(0xff1b293e)],
                            [Color(0xffa16a42), Color(0xff392338)],
                            [Color(0xff477b70), Color(0xff1b3038)],
                            [Color(0xff8056a0), Color(0xff30213e)],
                            [Color(0xff9b5360), Color(0xff34202d)],
                          ];
                          final colors = palettes[index % palettes.length];
                          final isFavorite = _favoriteIds.contains(item.id);
                          return Material(
                            color: const Color(0xff211e2a),
                            borderRadius: BorderRadius.circular(19),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => _openSeries(item),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  DecoratedBox(decoration: BoxDecoration(
                                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [colors[0], colors[1], const Color(0xff17141e)]),
                                  )),
                                  Positioned(top: 18, left: 0, right: 0, child: Icon(Icons.movie_filter_rounded, size: 104, color: const Color(0x33ffffff))),
                                  Positioned(top: 12, left: 12, child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                    decoration: BoxDecoration(color: const Color(0x44000000), borderRadius: BorderRadius.circular(20)),
                                    child: const Text('SÉRIE', style: TextStyle(fontSize: 8, letterSpacing: 1.2, fontWeight: FontWeight.w900)),
                                  )),
                                  Positioned(top: 5, right: 5, child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => setState(() { if (! _favoriteIds.add(item.id)) _favoriteIds.remove(item.id); }),
                                    icon: Icon(isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: isFavorite ? const Color(0xffff79aa) : Colors.white, size: 20),
                                  )),
                                  Positioned(left: 13, right: 13, bottom: 14, child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(width: 32, height: 32, decoration: BoxDecoration(color: const Color(0xffff6b9d), borderRadius: BorderRadius.circular(11)), child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 23)),
                                      const SizedBox(height: 11),
                                      Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, height: 1.12, fontWeight: FontWeight.w900)),
                                      const SizedBox(height: 5),
                                      const Text('ASSISTIR AGORA  ›', style: TextStyle(fontSize: 8, letterSpacing: 1.1, color: Color(0xfff5c9dc), fontWeight: FontWeight.w800)),
                                    ],
                                  )),
                                ],
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
                message: 'Coloque os vídeos dentro da pasta "${_selectedSeriesName ?? "da série"}" e atualize a lista.',
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
                        Text('${episodes.length} episódios • escolha onde continuar', style: const TextStyle(color: Color(0xffe5cbd9), fontSize: 12)),
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
                                  child: Text('${episodes[i].number == 0 ? i + 1 : episodes[i].number}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Color(0xffff8bb3))),
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
  bool _showPlaybackControl = true;
  Timer? _hideControlsTimer;
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
      if (mounted) {
        setState(() { _loading = false; _showPlaybackControl = true; });
        _scheduleHidePlaybackControl();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'O Google Drive não liberou a reprodução direta deste arquivo. Verifique se ele está público e se a API permite download. Detalhe: $e';
        });
      }
    }
  }

  void _scheduleHidePlaybackControl() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted || _controller == null || !_controller!.value.isPlaying) return;
      setState(() => _showPlaybackControl = false);
    });
  }

  void _togglePlayback() {
    final player = _controller;
    if (player == null) return;
    if (player.value.isPlaying) {
      _hideControlsTimer?.cancel();
      player.pause();
      setState(() => _showPlaybackControl = true);
    } else {
      player.play();
      setState(() => _showPlaybackControl = true);
      _scheduleHidePlaybackControl();
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
    _hideControlsTimer?.cancel();
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
            if (!_loading && _error == null && _controller != null && _controller!.value.isInitialized && _showPlaybackControl)
              Center(
                child: Material(
                  color: const Color(0x99000000),
                  shape: const CircleBorder(
                    side: BorderSide(color: Color(0x99ffffff), width: 1.5),
                  ),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _togglePlayback,
                    child: SizedBox(
                      width: 88,
                      height: 88,
                      child: Icon(
                        _controller!.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 58,
                      ),
                    ),
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
