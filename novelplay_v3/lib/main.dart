import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'catalog.dart';
import 'reelshort_web.dart';

void main() => runApp(const NovelPlay());

class NovelPlay extends StatelessWidget {
  const NovelPlay({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NovelPlay',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xffdc467b),
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late Future<Catalog> catalog = Sources.load();
  String search = '';
  String shelf = 'recommended';

  void refresh({String query = ''}) {
    setState(() {
      search = query;
      catalog = Sources.load(query: query, shelf: shelf);
    });
  }

  Future<void> configureApi() async {
    final controller = TextEditingController(text: Sources.reelshortApiUrl);
    final answer = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Conectar catálogo ReelShort'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Informe o endereço HTTPS de uma API compatível, '
                'terminando em /api/v1/reelshort.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Endereço da API',
                hintText: 'https://seu-servidor/api/v1/reelshort',
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'O catálogo pode ser consultado pelo aplicativo. '
              'A reprodução de vídeos ReelShort não é fornecida por esta integração.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || answer == null) return;
    if (answer.isNotEmpty && Sources.valid(answer) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Informe uma URL HTTPS válida.'),
      ));
      return;
    }
    Sources.reelshortApiUrl = answer;
    refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('NovelPlay'),
          actions: [
            IconButton(
              tooltip: 'Conectar API',
              onPressed: configureApi,
              icon: const Icon(Icons.settings_ethernet),
            ),
            IconButton(
              tooltip: 'Atualizar catálogo',
              onPressed: () => refresh(query: search),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: FutureBuilder<Catalog>(
          future: catalog,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Erro no catálogo: ' + snapshot.error.toString()),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final result = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Novelinhas',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text(result.origin,
                    style: const TextStyle(color: Colors.white70)),
                if (result.warning != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(result.warning!,
                        style: const TextStyle(color: Colors.amber)),
                  ),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(
                    labelText: 'Pesquisar pelo título',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Pesquisar na API',
                      onPressed: () => refresh(query: search),
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                  onChanged: (value) => search = value,
                  onSubmitted: (value) => refresh(query: value),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    _chip('Recomendados', 'recommended'),
                    _chip('Lançamentos', 'newrelease'),
                    _chip('Dublados', 'dramadub'),
                  ],
                ),
                if (result.novels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nenhuma novelinha encontrada nesta fonte.'),
                  ),
                for (final novel in result.novels)
                  Card(
                    child: ListTile(
                      leading: Cover(novel.cover),
                      title: Text(novel.title),
                      subtitle: Text(novel.genre),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => Details(novel),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );

  Widget _chip(String title, String value) => ChoiceChip(
        label: Text(title),
        selected: shelf == value,
        onSelected: (_) {
          shelf = value;
          refresh();
        },
      );
}

class Cover extends StatelessWidget {
  final String url;
  const Cover(this.url, {super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 64,
        height: 84,
        child: Sources.valid(url) != null
            ? Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    const Icon(Icons.movie),
              )
            : const Icon(Icons.movie),
      );
}

class Details extends StatefulWidget {
  final Novel novel;
  const Details(this.novel, {super.key});

  @override
  State<Details> createState() => _DetailsState();
}

class _DetailsState extends State<Details> {
  late Future<Novel> request = Sources.details(widget.novel);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.novel.title)),
        body: FutureBuilder<Novel>(
          future: request,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Falha ao buscar episódios: ' +
                      snapshot.error.toString()),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final novel = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Cover(novel.cover),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(novel.title,
                              style: Theme.of(context).textTheme.titleLarge),
                          Text(novel.synopsis),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text('Episódios',
                    style:
                        TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                if (novel.fromReelShort)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Assista pela página oficial do ReelShort, '
                          'aberta dentro do NovelPlay. Episódios premium '
                          'continuam sujeitos ao acesso da plataforma.',
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: () => _watchOfficial(context, novel),
                          icon: const Icon(Icons.play_circle_fill),
                          label: const Text('Assistir no ReelShort'),
                        ),
                      ],
                    ),
                  ),
                if (novel.episodes.isEmpty)
                  const Text('Não há episódios nesta fonte.'),
                for (final episode in novel.episodes)
                  ListTile(
                    leading: CircleAvatar(child: Text(episode.number.toString())),
                    title: Text(episode.title),
                    subtitle: novel.fromReelShort
                        ? const Text('Abrir página oficial para selecionar')
                        : episode.videoUrl.isEmpty
                            ? const Text('Reprodução indisponível')
                            : null,
                    trailing: Icon(
                      novel.fromReelShort
                          ? Icons.open_in_browser
                          : episode.videoUrl.isEmpty
                              ? Icons.lock_outline
                              : Icons.play_arrow,
                    ),
                    onTap: novel.fromReelShort
                        ? () => _watchOfficial(context, novel)
                        : episode.videoUrl.isEmpty
                            ? null
                            : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => Player(episode),
                                  ),
                                ),
                  ),
              ],
            );
          },
        ),
      );
}

void _watchOfficial(BuildContext context, Novel novel) {
  final uri = ReelShortPage.movieUrl(novel.slug, novel.id);
  if (uri == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Endereço oficial indisponível.')),
    );
    return;
  }
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReelShortPage(url: uri, title: novel.title),
    ),
  );
}

class Player extends StatefulWidget {
  final Episode episode;
  const Player(this.episode, {super.key});

  @override
  State<Player> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  VideoPlayerController? controller;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    final uri = Sources.valid(widget.episode.videoUrl);
    if (uri == null) {
      if (mounted) {
        setState(() {
          error = 'Endereço de vídeo ausente ou inválido.';
          loading = false;
        });
      }
      return;
    }
    final player = VideoPlayerController.networkUrl(uri);
    controller = player;
    try {
      await player.initialize();
      if (!mounted) return;
      setState(() => loading = false);
      await player.play();
    } catch (caught) {
      if (mounted) {
        setState(() {
          error = 'Não foi possível reproduzir o vídeo: $caught';
          loading = false;
        });
      }
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
                      padding: const EdgeInsets.all(20),
                      child: Text(error!, textAlign: TextAlign.center),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (controller != null)
                          AspectRatio(
                            aspectRatio: controller!.value.aspectRatio > 0
                                ? controller!.value.aspectRatio
                                : 9 / 16,
                            child: VideoPlayer(controller!),
                          ),
                        const SizedBox(height: 16),
                        IconButton.filled(
                          onPressed: () => setState(() {
                            if (controller!.value.isPlaying) {
                              controller!.pause();
                            } else {
                              controller!.play();
                            }
                          }),
                          icon: Icon(controller!.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow),
                        ),
                      ],
                    ),
        ),
      );
}
