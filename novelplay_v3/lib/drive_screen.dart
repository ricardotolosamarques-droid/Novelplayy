import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'rewarded_ads.dart';
import 'reelshort_catalog_screen.dart';
import 'published_catalog_screen.dart';

const _folderId = '1O28a3-3bmKkVj_3dS9HlWX0Owyn3eFts';
const _apiKey = String.fromEnvironment('DRIVE_API_KEY');

class DriveSeries {
  const DriveSeries(this.id, this.name, {this.coverId});
  final String id;
  final String name;
  final String? coverId;
}

class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.seriesId, required this.seriesName, required this.episodeId,
    required this.episodeName, required this.positionMs, required this.durationMs,
    required this.updatedAt,
  });
  final String seriesId, seriesName, episodeId, episodeName;
  final int positionMs, durationMs, updatedAt;
  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) => WatchHistoryEntry(
    seriesId: json['seriesId'] as String? ?? '',
    seriesName: json['seriesName'] as String? ?? 'Novelinha',
    episodeId: json['episodeId'] as String? ?? '',
    episodeName: json['episodeName'] as String? ?? 'Episódio',
    positionMs: json['positionMs'] as int? ?? 0,
    durationMs: json['durationMs'] as int? ?? 0,
    updatedAt: json['updatedAt'] as int? ?? 0,
  );
  Map<String, dynamic> toJson() => {
    'seriesId': seriesId, 'seriesName': seriesName, 'episodeId': episodeId,
    'episodeName': episodeName, 'positionMs': positionMs,
    'durationMs': durationMs, 'updatedAt': updatedAt,
  };
  double get progress => durationMs <= 0 ? 0.0 : (positionMs / durationMs).clamp(0.0, 1.0).toDouble();
}

class DriveEpisode {
  const DriveEpisode(this.id, this.name, this.mimeType, {this.resourceKey});
  final String id;
  final String name;
  final String mimeType;
  final String? resourceKey;

  Map<String, String> get resourceHeaders => resourceKey == null || resourceKey!.isEmpty
      ? const <String, String>{}
      : <String, String>{'X-Goog-Drive-Resource-Keys': '$id/$resourceKey'};

  int get number {
    final match = RegExp(r'\d+').firstMatch(name);
    return match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
  }

  // Primeiro tenta o endpoint oficial da API; depois o link direto de
  // download do Drive, útil para arquivos compartilhados publicamente.
  Uri get mediaUri => Uri.https(
        'www.googleapis.com',
        '/drive/v3/files/$id',
        {'alt': 'media', 'key': _apiKey},
      );

  Uri get directDownloadUri => Uri.https(
        'drive.google.com',
        '/uc',
        <String, String>{
      'export': 'download',
      'id': id,
      'confirm': 't',
      if (resourceKey != null && resourceKey!.isNotEmpty) 'resourcekey': resourceKey!,
    },
      );
}

class DriveNovelScreen extends StatefulWidget {
  final bool isAdmin;
  const DriveNovelScreen({super.key, this.isAdmin = false});

  @override
  State<DriveNovelScreen> createState() => _DriveNovelScreenState();
}

class _DriveNovelScreenState extends State<DriveNovelScreen> {
  String? _selectedFolderId;
  String? _selectedSeriesName;
  String _searchQuery = '';
  final Set<String> _favoriteIds = <String>{};
  int _tabIndex = 0;
  int _bottomIndex = 0;
  bool _openingSeries = false;
  late Future<List<dynamic>> _content = _loadSeries();
  late Future<List<WatchHistoryEntry>> _historyFuture = _loadHistory();
  Timer? _profileClock;

  @override
  void initState() {
    super.initState();
    _profileClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _bottomIndex == 4 && _selectedFolderId == null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _profileClock?.cancel();
    super.dispose();
  }

  Future<List<WatchHistoryEntry>> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('novelinha_watch_history');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.whereType<Map<String, dynamic>>()
          .map(WatchHistoryEntry.fromJson).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (_) { return []; }
  }


  Future<void> _watchAdFromProfile() async {
    final messenger = ScaffoldMessenger.of(context);
    final earned = await NovelRewardedAds.watchAdForMoreAccess();
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(
      content: Text(earned
          ? 'Pronto! Você ganhou mais 30 minutos sem anúncios.'
          : 'O anúncio não foi concluído. Nenhum tempo foi adicionado.'),
    ));
  }

  Widget _profilePage() {
    return FutureBuilder<Duration>(
      future: NovelRewardedAds.remainingAccess(),
      builder: (context, snapshot) {
        final remaining = snapshot.data ?? Duration.zero;
        final active = remaining > Duration.zero;
        final hours = remaining.inHours;
        final minutes = remaining.inMinutes.remainder(60);
        final seconds = remaining.inSeconds.remainder(60);
        final timeLabel = active
            ? hours > 0
                ? '${hours}h ${minutes.toString().padLeft(2, '0')}min'
                : '${minutes.toString().padLeft(2, '0')}min ${seconds.toString().padLeft(2, '0')}s'
            : 'Tempo esgotado';
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 24),
            const CircleAvatar(
              radius: 42,
              backgroundColor: Color(0xff38202a),
              child: Icon(Icons.person_rounded, size: 48, color: Color(0xffff6b9d)),
            ),
            const SizedBox(height: 14),
            const Center(child: Text('MEU PERFIL', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900))),
            const SizedBox(height: 26),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(colors: [Color(0xff702b59), Color(0xff30203f)]),
                border: Border.all(color: const Color(0x55ff6b9d)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.timer_outlined, color: Color(0xffff8bb3)),
                    SizedBox(width: 8),
                    Text('TEMPO SEM ANÚNCIOS', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.7)),
                  ]),
                  const SizedBox(height: 15),
                  Text(timeLabel, style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 7),
                  Text(
                    active ? 'Você pode assistir a todas as novelinhas enquanto esse tempo estiver ativo.' : 'Assista a um anúncio para liberar 30 minutos de acesso.',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _openingSeries ? null : _watchAdFromProfile,
                      icon: const Icon(Icons.play_circle_fill),
                      label: const Text('ASSISTIR ANÚNCIO E GANHAR +30 MIN'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xffe51b3e),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text('Dica: você pode assistir a vários anúncios para acumular tempo, mesmo antes de o tempo atual acabar.', style: TextStyle(color: Colors.white60, height: 1.4)),
          ],
        );
      },
    );
  }

  Future<void> _resumeHistory(WatchHistoryEntry entry) async {
    try {
      final episodes = await _loadEpisodes(entry.seriesId);
      if (!mounted || episodes.isEmpty) return;
      final found = episodes.indexWhere((episode) => episode.id == entry.episodeId);
      final index = found < 0 ? 0 : found;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => _DrivePlayerPage(
        episodes: episodes, initialIndex: index, seriesId: entry.seriesId,
        seriesName: entry.seriesName,
        initialPosition: found < 0 ? Duration.zero : Duration(milliseconds: entry.positionMs),
      )));
      if (mounted) setState(() => _historyFuture = _loadHistory());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível retomar: $e')),
      );
    }
  }

  Future<List<Map<String, dynamic>>> _listChildren(String parentId) async {
    final allFiles = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final params = <String, String>{
        'q': "'$parentId' in parents and trashed = false",
        'key': _apiKey,
        'pageSize': '1000',
        'orderBy': 'name',
        'fields': 'files(id,name,mimeType,resourceKey),nextPageToken',
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

    // Processa poucas séries por vez para não sobrecarregar a API do Drive.
    final result = <DriveSeries>[];
    for (var start = 0; start < folders.length; start += 4) {
      final batch = folders.skip(start).take(4);
      final loaded = await Future.wait(batch.map((series) async {
        try {
          final children = await _listChildren(series.id);
          Map<String, dynamic>? cover;
          for (final file in children) {
            if ((file['mimeType'] as String? ?? '').startsWith('image/')) {
              cover = file;
              break;
            }
          }
          return cover == null ? series : DriveSeries(series.id, series.name, coverId: cover['id'] as String?);
        } catch (_) {
          return series;
        }
      }));
      result.addAll(loaded);
    }
    return result;
  }

  Future<List<DriveEpisode>> _loadEpisodes(String folderId) async {
    final files = await _listChildren(folderId);
    final episodes = files
        .where((file) => (file['mimeType'] as String? ?? '').startsWith('video/'))
        .map((file) => DriveEpisode(
              file['id'] as String,
              (file['name'] as String?) ?? 'Episódio',
              (file['mimeType'] as String?) ?? '',
              resourceKey: file['resourceKey'] as String?,
            ))
        .toList();
    episodes.sort((a, b) {
      final byNumber = a.number.compareTo(b.number);
      return byNumber != 0 ? byNumber : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return episodes;
  }

  Widget _homeCategory(String label, int index) {
    final selected = _tabIndex == index;
    return Padding(
      padding: const EdgeInsets.only(right: 22),
      child: InkWell(
        onTap: () => setState(() => _tabIndex = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: TextStyle(
              color: selected ? Colors.white : const Color(0xffaaa4b4),
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.4,
            )),
            const SizedBox(height: 7),
            if (selected) Container(width: 24, height: 3,
              decoration: BoxDecoration(color: const Color(0xffff315b), borderRadius: BorderRadius.circular(4))),
          ],
        ),
      ),
    );
  }

  Future<void> _openSeries(DriveSeries series) async {
    if (_openingSeries) return;
    _openingSeries = true;
    try {
      if (!widget.isAdmin) {
        final hasAdFreeAccess = await NovelRewardedAds.ensureAdFreeAccess();
        if (!hasAdFreeAccess) {
          throw Exception('Assista ao anúncio completo para liberar 30 minutos sem anúncios. Se o anúncio não carregar, tente novamente mais tarde.');
        }
      }
      if (!mounted) return;
      setState(() {
        _selectedFolderId = series.id;
        _selectedSeriesName = series.name;
        _content = _loadEpisodes(series.id);
      });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível desbloquear: ${error.toString().replaceFirst('Exception: ', '')}')),
      );
    } finally {
      _openingSeries = false;
    }
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
                currentIndex: _bottomIndex,
                onTap: (index) => setState(() => _bottomIndex = index),
                backgroundColor: const Color(0xff080808),
                selectedItemColor: Colors.white,
                unselectedItemColor: const Color(0xff858585),
                type: BottomNavigationBarType.fixed,
                selectedFontSize: 10,
                unselectedFontSize: 10,
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Página inicial'),
                  BottomNavigationBarItem(icon: Icon(Icons.smart_display_outlined), label: 'Para você'),
                  BottomNavigationBarItem(icon: Icon(Icons.bookmark_border_rounded), label: 'Minha lista'),
                  BottomNavigationBarItem(icon: Icon(Icons.card_giftcard_rounded), label: 'Recompensas'),
                  BottomNavigationBarItem(icon: Icon(Icons.person_outline_rounded), label: 'Perfil'),
                  BottomNavigationBarItem(icon: Icon(Icons.video_library_outlined), label: 'ReelShort'),
                  BottomNavigationBarItem(icon: Icon(Icons.cloud_done_outlined), label: 'Catálogo'),
                ],
              )
            : null,
        body: _selectedFolderId == null && _bottomIndex == 6
            ? const PublishedCatalogScreen()
            : _selectedFolderId == null && _bottomIndex == 5
                ? ReelShortCatalogScreen(isAdmin: widget.isAdmin)
                : FutureBuilder<List<dynamic>>(
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
              if (_bottomIndex == 4) return _profilePage();
              final series = allSeries.where((item) {
                final matchesSearch = item.name.toLowerCase().contains(_searchQuery.toLowerCase());
                final matchesTab = _bottomIndex != 2 || _favoriteIds.contains(item.id);
                return matchesSearch && matchesTab;
              }).toList();
              if (allSeries.isEmpty) {
                return _DriveMessage(
                  title: 'Nenhuma série encontrada',
                  message: 'Crie uma pasta para cada novelinha dentro da pasta principal do Google Drive. O nome da pasta será o nome da série. Para usar um pôster, coloque uma imagem dentro da pasta da série junto com os episódios.',
                  onRetry: _refresh,
                );
              }
              return RefreshIndicator(
                color: const Color(0xffe51b3e),
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
                  children: [
                    Row(children: [
                      Container(width: 38, height: 38, decoration: BoxDecoration(color: const Color(0xffe51b3e), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28)),
                      const SizedBox(width: 9),
                      const Expanded(child: Text('NOVELPLAY', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: 1.5))),
                      InkWell(
                        onTap: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Área VIP em breve.'))),
                        borderRadius: BorderRadius.circular(9),
                        child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xff875222), Color(0xffd6a64b)]), borderRadius: BorderRadius.circular(9)), child: const Row(children: [Icon(Icons.workspace_premium, size: 18), SizedBox(width: 5), Text('VIP', style: TextStyle(fontWeight: FontWeight.w900))])),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(child: TextField(
                        onChanged: (value) => setState(() => _searchQuery = value),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Buscar novelinhas...',
                          hintStyle: const TextStyle(color: Color(0xff999999), fontSize: 13),
                          prefixIcon: const Icon(Icons.search, color: Colors.white70),
                          filled: true, fillColor: const Color(0xff292929),
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xff444444))),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xffe51b3e))),
                        ),
                      )),
                      IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh, color: Colors.white70)),
                    ]),
                    const SizedBox(height: 15),
                    SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, children: [
                      _homeCategory('POPULAR', 0),
                      _homeCategory('NOVO', 1),
                      _homeCategory('CLASSIFICAÇÃO', 2),
                      _homeCategory('CATEGORIAS', 3),
                    ])),
                    if (_bottomIndex != 2) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: series.isEmpty ? null : () => _openSeries(series.first),
                        child: Container(
                          height: 410, clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(color: const Color(0xff242424), borderRadius: BorderRadius.circular(5)),
                          child: Stack(fit: StackFit.expand, children: [
                            if (series.isNotEmpty && series.first.coverId != null)
                              Image.network('https://drive.google.com/uc?export=view&id=${series.first.coverId}', fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xff421923)))
                            else
                              const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xff751b2a), Color(0xff151515)], begin: Alignment.topLeft, end: Alignment.bottomRight)), child: Icon(Icons.movie_creation_outlined, size: 130, color: Color(0x44ffffff))),
                            const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0x33000000), Color(0xf0000000)], stops: [0.30, 0.57, 1]))),
                            Positioned(left: 17, right: 17, bottom: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: const Color(0xffe51b3e), borderRadius: BorderRadius.circular(4)), child: const Text('NOVELPLAY EXCLUSIVO', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900))),
                              const SizedBox(height: 9),
                              Text(series.isEmpty ? 'Descubra sua próxima história' : series.first.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 27, height: 1.05, fontWeight: FontWeight.w900)),
                              const SizedBox(height: 7),
                              const Text('Romance  •  Drama  •  Histórias emocionantes', style: TextStyle(color: Colors.white70, fontSize: 11)),
                              const SizedBox(height: 15),
                              Container(padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.play_arrow_rounded, color: Colors.black, size: 21), SizedBox(width: 6), Text('REPRODUZIR', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 14))])),
                            ])),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Center(child: Text('●  ━  ●  ●  ●  ●', style: TextStyle(color: Colors.white70, fontSize: 10, letterSpacing: 3))),
                    ],
                    const SizedBox(height: 22),
                    Row(children: [
                      Expanded(child: Text(_bottomIndex == 2 ? 'MINHA LISTA' : _tabIndex == 1 ? 'NOVOS DRAMAS' : _tabIndex == 2 ? 'CLASSIFICAÇÃO' : 'NOVELINHAS PARA ASSISTIR', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
                      Text('${series.length} títulos', style: const TextStyle(color: Color(0xff999999), fontSize: 11)),
                    ]),
                    const SizedBox(height: 13),
                    if (series.isEmpty)
                      const Padding(padding: EdgeInsets.all(24), child: Text('Nenhuma novelinha encontrada. Sua lista aparece aqui quando você salvar uma série.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)))
                    else
                      GridView.builder(
                        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                        itemCount: series.length,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 9, mainAxisSpacing: 13, childAspectRatio: 0.62),
                        itemBuilder: (context, index) {
                          final item = series[index];
                          final favorite = _favoriteIds.contains(item.id);
                          return Material(
                            color: const Color(0xff242424), borderRadius: BorderRadius.circular(5), clipBehavior: Clip.antiAlias,
                            child: InkWell(onTap: () => _openSeries(item), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(child: Stack(fit: StackFit.expand, children: [
                                if (item.coverId != null)
                                  Image.network('https://drive.google.com/uc?export=view&id=${item.coverId}', fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xff38202a), child: Icon(Icons.movie_outlined, size: 55, color: Colors.white38)))
                                else
                                  const ColoredBox(color: Color(0xff38202a), child: Icon(Icons.movie_outlined, size: 55, color: Colors.white38)),
                                Positioned(left: 6, top: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4), decoration: BoxDecoration(color: const Color(0xff7134e8), borderRadius: BorderRadius.circular(4)), child: const Text('NOVEL', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900)))),
                                Positioned(right: 2, top: 1, child: IconButton(visualDensity: VisualDensity.compact, onPressed: () => setState(() { if (!_favoriteIds.add(item.id)) _favoriteIds.remove(item.id); }), icon: Icon(favorite ? Icons.favorite : Icons.favorite_border, color: favorite ? const Color(0xffff3155) : Colors.white, size: 19))),
                              ])),
                              Padding(padding: const EdgeInsets.fromLTRB(9, 8, 9, 9), child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.15, fontWeight: FontWeight.w700))),
                            ])),
                          );
                        },
                      ),
                    if (_bottomIndex == 0)
                      FutureBuilder<List<WatchHistoryEntry>>(
                        future: _historyFuture,
                        builder: (context, snapshot) {
                          final history = snapshot.data ?? [];
                          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const SizedBox(height: 22),
                            const Text('CONTINUE ASSISTINDO', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 12),
                            SizedBox(height: 112, child: history.isEmpty
                              ? Container(decoration: BoxDecoration(color: const Color(0xff242424), borderRadius: BorderRadius.circular(7)), padding: const EdgeInsets.all(13), child: const Row(children: [Icon(Icons.play_circle_outline, color: Color(0xffe51b3e), size: 32), SizedBox(width: 10), Expanded(child: Text('Assista a uma novelinha e seu progresso aparecerá aqui.', style: TextStyle(color: Colors.white70, fontSize: 12)))]))
                              : ListView.separated(scrollDirection: Axis.horizontal, itemCount: history.length, separatorBuilder: (_, __) => const SizedBox(width: 9), itemBuilder: (context, index) {
                                  final entry = history[index];
                                  return SizedBox(width: 245, child: Material(color: const Color(0xff242424), borderRadius: BorderRadius.circular(7), child: InkWell(onTap: () => _resumeHistory(entry), child: Padding(padding: const EdgeInsets.all(10), child: Row(children: [
                                    Container(width: 55, height: 78, decoration: BoxDecoration(color: const Color(0xff4a202b), borderRadius: BorderRadius.circular(5)), child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 28)),
                                    const SizedBox(width: 10),
                                    Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(entry.seriesName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
                                      const SizedBox(height: 5),
                                      Text(entry.episodeName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 10)),
                                      const SizedBox(height: 8),
                                      ClipRRect(borderRadius: BorderRadius.circular(5), child: LinearProgressIndicator(value: entry.progress, minHeight: 4, backgroundColor: Colors.white12, valueColor: const AlwaysStoppedAnimation(Color(0xffe51b3e)))),
                                      const SizedBox(height: 5),
                                      const Text('CONTINUAR', style: TextStyle(color: Color(0xffff7389), fontSize: 8, fontWeight: FontWeight.w900)),
                                    ])),
                                  ])))));
                                })),
                          ]);
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
                          onTap: () async {
                            await Navigator.push(context, MaterialPageRoute(builder: (_) => _DrivePlayerPage(
                              episodes: episodes, initialIndex: i,
                              seriesId: _selectedFolderId!, seriesName: _selectedSeriesName ?? 'Novelinha',
                            )));
                            if (mounted) setState(() => _historyFuture = _loadHistory());
                          },
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
  const _DrivePlayerPage({
    required this.episodes, required this.initialIndex, required this.seriesId,
    required this.seriesName, this.initialPosition = Duration.zero,
  });
  final List<DriveEpisode> episodes;
  final int initialIndex;
  final String seriesId, seriesName;
  final Duration initialPosition;

  @override
  State<_DrivePlayerPage> createState() => _DrivePlayerPageState();
}

class _DrivePlayerPageState extends State<_DrivePlayerPage> {
  late final PageController _pageController;
  late int _index;
  VideoPlayerController? _controller;
  VideoPlayerController? _nextController;
  int? _nextControllerIndex;
  bool _preloadingNext = false;
  int _autoAdvancedIndex = -1;
  bool _loading = true;
  bool _showPlaybackControl = true;
  Timer? _hideControlsTimer;
  String? _error;
  DateTime _lastHistorySave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _restoredInitialPosition = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    _initialize();
  }

  Future<VideoPlayerController> _createInitializedPlayer(DriveEpisode episode) async {
    VideoPlayerController? player;
    Object? apiError;
    try {
      player = VideoPlayerController.networkUrl(episode.mediaUri, httpHeaders: episode.resourceHeaders);
      await player.initialize();
      return player;
    } catch (error) {
      apiError = error;
      await player?.dispose();
      player = VideoPlayerController.networkUrl(episode.directDownloadUri, httpHeaders: episode.resourceHeaders);
      try {
        await player.initialize();
        return player;
      } catch (fallbackError) {
        await player.dispose();
        throw Exception('A API do Drive recusou: $apiError. O link direto também falhou: $fallbackError. Confira se o vídeo está compartilhado como "Qualquer pessoa com o link" e com acesso de leitor.');
      }
    }
  }

  Future<void> _preloadNextEpisode() async {
    if (_preloadingNext || _nextController != null || _index >= widget.episodes.length - 1) return;
    _preloadingNext = true;
    final targetIndex = _index + 1;
    VideoPlayerController? candidate;
    try {
      candidate = await _createInitializedPlayer(widget.episodes[targetIndex]);
      if (!mounted || _index + 1 != targetIndex || _nextController != null) {
        await candidate.dispose();
        return;
      }
      _nextController = candidate;
      _nextControllerIndex = targetIndex;
    } catch (_) {
      // Se o pré-carregamento falhar, a troca normal tentará abrir o episódio.
    } finally {
      _preloadingNext = false;
    }
  }

  Future<void> _initialize() async {
    final previous = _controller;
    final prepared = _nextControllerIndex == _index ? _nextController : null;
    _controller = prepared;
    if (prepared != null) {
      _nextController = null;
      _nextControllerIndex = null;
    } else {
      _controller = null;
    }
    await previous?.dispose();
    if (!mounted) {
      if (prepared != null) await prepared.dispose();
      return;
    }
    setState(() {
      _loading = prepared == null;
      _error = null;
    });

    try {
      final episode = widget.episodes[_index];
      final player = prepared ?? await _createInitializedPlayer(episode);
      _controller = player;
      if (!_restoredInitialPosition && _index == widget.initialIndex && widget.initialPosition > Duration.zero) {
        final target = widget.initialPosition < player.value.duration ? widget.initialPosition : player.value.duration;
        if (target > Duration.zero) await player.seekTo(target);
        _restoredInitialPosition = true;
      }
      player.addListener(_onVideoChanged);
      await player.play();
      // Prepara o próximo vídeo enquanto o atual ainda está tocando.
      unawaited(_preloadNextEpisode());
      await WakelockPlus.enable();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: const [SystemUiOverlay.bottom]);
      if (mounted) {
        setState(() { _loading = false; _showPlaybackControl = true; });
        _scheduleHidePlaybackControl();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Falha ao abrir o vídeo. Detalhe técnico: $e';
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
      WakelockPlus.disable();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
      setState(() => _showPlaybackControl = true);
    } else {
      player.play();
      WakelockPlus.enable();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: const [SystemUiOverlay.bottom]);
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

  Future<void> _persistCurrentProgress() async {
    final player = _controller;
    if (player == null || !player.value.isInitialized || _index >= widget.episodes.length) return;
    final position = player.value.position, duration = player.value.duration;
    if (position <= Duration.zero || duration <= Duration.zero) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('novelinha_watch_history');
    List<WatchHistoryEntry> current = [];
    if (raw != null) {
      try {
        current = (jsonDecode(raw) as List<dynamic>)
            .whereType<Map<String, dynamic>>().map(WatchHistoryEntry.fromJson).toList();
      } catch (_) {}
    }
    final episode = widget.episodes[_index];
    final entry = WatchHistoryEntry(
      seriesId: widget.seriesId, seriesName: widget.seriesName,
      episodeId: episode.id, episodeName: episode.name,
      positionMs: position.inMilliseconds, durationMs: duration.inMilliseconds,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final updated = [entry, ...current.where((item) => item.seriesId != widget.seriesId)]
        .take(20).map((item) => item.toJson()).toList();
    await prefs.setString('novelinha_watch_history', jsonEncode(updated));
  }

  void _onVideoChanged() {
    final player = _controller;
    if (player == null || !player.value.isInitialized) return;
    if (DateTime.now().difference(_lastHistorySave).inSeconds >= 2) {
      _lastHistorySave = DateTime.now();
      _persistCurrentProgress();
    }
    if (player.value.duration > Duration.zero &&
        player.value.position >= player.value.duration &&
        !player.value.isPlaying &&
        _index < widget.episodes.length - 1 &&
        _autoAdvancedIndex != _index) {
      _autoAdvancedIndex = _index;
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    // O indicador de progresso observa o controller; não reconstruir a tela
    // inteira a cada atualização de posição do vídeo.
  }

  Future<void> _showEpisodePicker() async {
    _hideControlsTimer?.cancel();
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        final screenHeight = MediaQuery.of(sheetContext).size.height;
        return Container(
          height: screenHeight * 0.72,
          decoration: const BoxDecoration(
            color: Color(0xff111114),
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xff55555b),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Episódios',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            widget.seriesName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xffa6a6ad),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xff25252b),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${widget.episodes.length} episódios',
                        style: const TextStyle(
                          color: Color(0xffd8d8dc),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xff29292e)),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                  itemCount: widget.episodes.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 11,
                    crossAxisSpacing: 11,
                    childAspectRatio: 1.18,
                  ),
                  itemBuilder: (_, i) {
                    final episode = widget.episodes[i];
                    final number = episode.number == 0 ? i + 1 : episode.number;
                    final active = i == _index;
                    return Material(
                      color: active ? const Color(0xffe91e50) : const Color(0xff242429),
                      borderRadius: BorderRadius.circular(9),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(9),
                        onTap: () => Navigator.pop(sheetContext, i),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: active ? const Color(0xffff7898) : const Color(0xff34343b),
                              width: active ? 1.4 : 0.8,
                            ),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$number',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: active ? FontWeight.w900 : FontWeight.w700,
                                  ),
                                ),
                                if (active) ...[
                                  const SizedBox(height: 2),
                                  const Text(
                                    'ATUAL',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 7,
                                      letterSpacing: 0.7,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (selected != null && selected != _index) {
      await _persistCurrentProgress();
      await _pageController.animateToPage(
        selected,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    } else if (_controller != null && _controller!.value.isPlaying) {
      _scheduleHidePlaybackControl();
    }
  }

  @override
  void dispose() {
    _persistCurrentProgress();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    _hideControlsTimer?.cancel();
    _controller?.removeListener(_onVideoChanged);
    _controller?.dispose();
    _nextController?.dispose();
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
              onPageChanged: (value) async {
                await _persistCurrentProgress();
                if (!mounted) return;
                setState(() => _index = value);
                await _initialize();
              },
              itemBuilder: (_, __) => const ColoredBox(color: Colors.black),
            ),
            // Captura explicitamente o gesto vertical. O PageView fica
            // programático para evitar disputa de gestos com o player de vídeo.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (!_showPlaybackControl && _controller != null && _controller!.value.isPlaying) {
                    setState(() => _showPlaybackControl = true);
                    _scheduleHidePlaybackControl();
                  }
                },
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
                    onPressed: () async {
                      await _persistCurrentProgress();
                      if (mounted) Navigator.pop(context);
                    },
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
            if (_controller != null && _controller!.value.isInitialized) ...[
              Positioned(
                left: 16,
                right: 16,
                bottom: 8,
                child: Center(
                  child: Material(
                    color: const Color(0xdd17141f),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _showEpisodePicker,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.video_library_rounded,
                              color: Color(0xffff83b0), size: 19),
                            const SizedBox(width: 9),
                            Flexible(
                              child: Text(
                                '${widget.seriesName}  •  Episódio ${widget.episodes[_index].number == 0 ? _index + 1 : widget.episodes[_index].number}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white,
                                  fontSize: 12, fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(width: 7),
                            const Icon(Icons.keyboard_arrow_up_rounded,
                              color: Colors.white70, size: 19),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 58,
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(playedColor: Color(0xffff6da8)),
                ),
              ),
            ],
          ],
        ),
      );
}
