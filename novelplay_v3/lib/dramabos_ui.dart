import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dramabos_api.dart';

class DramaBosHome extends StatefulWidget {
  const DramaBosHome({super.key});

  @override
  State<DramaBosHome> createState() => _DramaBosHomeState();
}

class _DramaBosHomeState extends State<DramaBosHome> {
  final searchController = TextEditingController();
  late DramaProvider provider;
  late Future<List<DramaItem>> catalog;
  String activeSearch = '';

  @override
  void initState() {
    super.initState();
    provider = DramaBosApi.providers.firstWhere((p) => p.slug == 'dramabox');
    catalog = DramaBosApi.home(provider);
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  void refresh([String? query]) {
    final text = query ?? activeSearch;
    setState(() {
      activeSearch = text.trim();
      catalog = DramaBosApi.search(provider, activeSearch);
    });
  }

  void chooseProvider(DramaProvider next) {
    searchController.clear();
    setState(() {
      provider = next;
      activeSearch = '';
      catalog = DramaBosApi.home(next);
    });
  }

  Widget cover(String address) {
    final url = Uri.tryParse(address);
    if (url?.scheme != 'https') {
      return const Icon(Icons.movie_creation_outlined, size: 38);
    }
    return Image.network(
      address,
      width: 66,
      height: 90,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) =>
          const Icon(Icons.movie_creation_outlined, size: 38),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('NovelPlay'),
      actions: [
        IconButton(
          tooltip: 'Atualizar catálogo',
          onPressed: () => refresh(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('42 plataformas • DramaBos',
                style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text(
                'Escolha uma plataforma. Os episódios disponíveis '
                'podem ser assistidos aqui, sem abrir outros sites.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<DramaProvider>(
                value: provider,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Plataforma',
                  prefixIcon: Icon(Icons.live_tv),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final item in DramaBosApi.providers)
                    DropdownMenuItem(
                      value: item,
                      child: Text(item.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (item) {
                  if (item != null) chooseProvider(item);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Buscar novelinhas em ' + provider.name,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Pesquisar',
                    onPressed: () => refresh(searchController.text),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
                onSubmitted: refresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<DramaItem>>(
            future: catalog,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_off, size: 48),
                        const SizedBox(height: 12),
                        const Text('Não foi possível consultar a DramaBos.',
                            textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        Text(snapshot.error.toString(),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => refresh(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Tentar novamente'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final list = snapshot.data ?? [];
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(activeSearch.isEmpty
                        ? 'Esta plataforma não retornou títulos. '
                          'Pesquise um título usando o campo acima.'
                        : 'Nenhuma novelinha encontrada para esta pesquisa.'),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final drama = list[index];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: SizedBox(width: 66, height: 90,
                          child: cover(drama.cover)),
                      title: Text(drama.title),
                      subtitle: Text(
                        [
                          if (drama.genre.isNotEmpty) drama.genre,
                          if (drama.total > 0)
                            drama.total.toString() + ' episódios',
                        ].join(' • '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              DramaBosDetails(provider: provider, drama: drama),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

class DramaBosDetails extends StatefulWidget {
  final DramaProvider provider;
  final DramaItem drama;
  const DramaBosDetails({
    super.key,
    required this.provider,
    required this.drama,
  });

  @override
  State<DramaBosDetails> createState() => _DramaBosDetailsState();
}

class _DramaBosDetailsState extends State<DramaBosDetails> {
  late Future<List<DramaEpisode>> episodes;

  @override
  void initState() {
    super.initState();
    episodes = DramaBosApi.episodes(widget.provider, widget.drama);
  }

  void retry() => setState(() {
    episodes = DramaBosApi.episodes(widget.provider, widget.drama);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.drama.title)),
    body: FutureBuilder<List<DramaEpisode>>(
      future: episodes,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Erro ao buscar episódios: ' +
                      snapshot.error.toString(), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: retry,
                    child: const Text('Tentar novamente'),
                  ),
                ],
              ),
            ),
          );
        }
        final list = snapshot.data ?? [];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.drama.title,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(widget.provider.name,
                style: const TextStyle(color: Colors.white70)),
            if (widget.drama.synopsis.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(widget.drama.synopsis),
            ],
            const SizedBox(height: 18),
            Text('Episódios (' + list.length.toString() + ')',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('Episódios pagos continuam indisponíveis.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('A API não retornou episódios.'),
              ),
            for (final episode in list)
              ListTile(
                leading: CircleAvatar(child: Text(episode.number.toString())),
                title: Text(episode.title),
                subtitle: Text(episode.locked
                    ? 'Bloqueado nesta integração'
                    : 'Assistir dentro do NovelPlay'),
                trailing: Icon(episode.locked
                    ? Icons.lock_outline : Icons.play_circle_fill),
                onTap: episode.locked ? null : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DramaBosPlayer(
                      provider: widget.provider,
                      drama: widget.drama,
                      episode: episode,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class DramaBosPlayer extends StatefulWidget {
  final DramaProvider provider;
  final DramaItem drama;
  final DramaEpisode episode;

  const DramaBosPlayer({
    super.key, required this.provider,
    required this.drama, required this.episode,
  });

  @override
  State<DramaBosPlayer> createState() => _DramaBosPlayerState();
}

class _DramaBosPlayerState extends State<DramaBosPlayer> {
  VideoPlayerController? controller;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      final address = await DramaBosApi.play(
          widget.provider, widget.drama, widget.episode);
      if (!mounted) return;
      final player = VideoPlayerController.networkUrl(address);
      controller = player;
      await player.initialize();
      if (!mounted) return;
      setState(() => loading = false);
      await player.play();
    } catch (ex) {
      if (!mounted) return;
      setState(() {
        error = 'Não foi possível reproduzir o episódio: ' + ex.toString();
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.episode.title)),
    body: Center(
      child: loading
          ? const CircularProgressIndicator()
          : error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error!, textAlign: TextAlign.center),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: controller!.value.aspectRatio > 0
                          ? controller!.value.aspectRatio : 9 / 16,
                      child: VideoPlayer(controller!),
                    ),
                    VideoProgressIndicator(
                      controller!,
                      allowScrubbing: true,
                      padding: const EdgeInsets.all(12),
                    ),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller!,
                      builder: (_, value, __) => IconButton.filled(
                        onPressed: () {
                          if (value.isPlaying) {
                            controller!.pause();
                          } else {
                            controller!.play();
                          }
                        },
                        icon: Icon(value.isPlaying
                            ? Icons.pause : Icons.play_arrow),
                      ),
                    ),
                  ],
                ),
    ),
  );
}
