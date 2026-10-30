import 'package:flutter/material.dart';
import 'dramabos_api.dart';

class DramaBosScreen extends StatefulWidget {
  const DramaBosScreen({super.key});
  @override
  State<DramaBosScreen> createState() => _DramaBosScreenState();
}
class _DramaBosScreenState extends State<DramaBosScreen> {
  final Future<bool> connected = DramaBosApi.connected();
  String filter = '';

  @override
  Widget build(BuildContext context) {
    final list = DramaBosApi.providers.where((p) =>
      p.name.toLowerCase().contains(filter.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('42 plataformas DramaBos')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        FutureBuilder<bool>(future: connected, builder: (context, state) {
          final active = state.data == true;
          return Text(
            active
              ? 'DramaBos conectada. Escolha uma plataforma para pesquisar.'
              : 'Catálogo de plataformas disponível. Para pesquisar dramas, '
                'é necessária uma chave DramaBos configurada no Render.',
            style: TextStyle(color: active ? null :
              Theme.of(context).colorScheme.onSurfaceVariant),
          );
        }),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Filtrar plataformas', prefixIcon: Icon(Icons.search)),
          onChanged: (s) => setState(() => filter = s),
        ),
        const SizedBox(height: 12),
        for (final provider in list) Card(child: ListTile(
          leading: const Icon(Icons.movie_filter_outlined),
          title: Text(provider.name),
          subtitle: const Text('Buscar títulos e episódios'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => DramaBosSearchScreen(provider: provider),
          )),
        )),
        if (list.isEmpty)
          const Padding(padding: EdgeInsets.all(18),
            child: Text('Nenhuma plataforma corresponde à pesquisa.')),
      ]),
    );
  }
}

class DramaBosSearchScreen extends StatefulWidget {
  final DramaProvider provider;
  const DramaBosSearchScreen({super.key, required this.provider});
  @override
  State<DramaBosSearchScreen> createState() => _DramaBosSearchScreenState();
}
class _DramaBosSearchScreenState extends State<DramaBosSearchScreen> {
  final field = TextEditingController();
  Future<List<DramaItem>>? results;

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  void search() {
    if (field.text.trim().isEmpty) return;
    setState(() {
      results = DramaBosApi.search(widget.provider, field.text.trim());
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.provider.name)),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(
        controller: field,
        decoration: const InputDecoration(
          labelText: 'Título da novelinha',
          prefixIcon: Icon(Icons.search),
        ),
        onSubmitted: (_) => search(),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: search,
        icon: const Icon(Icons.search),
        label: const Text('Pesquisar pela DramaBos'),
      ),
      const SizedBox(height: 14),
      if (results == null)
        const Text('Pesquise um título para consultar o catálogo da plataforma.'),
      if (results != null)
        FutureBuilder<List<DramaItem>>(future: results, builder: (context, snap) {
          if (snap.hasError) {
            return Text('Não foi possível pesquisar: ' + snap.error.toString());
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.data!.isEmpty) {
            return const Text('Nenhuma novelinha encontrada.');
          }
          return Column(children: [
            for (final drama in snap.data!) Card(child: ListTile(
              leading: const Icon(Icons.movie),
              title: Text(drama.title),
              subtitle: Text(drama.genre),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => DramaBosEpisodesScreen(
                  drama: drama, provider: widget.provider),
              )),
            )),
          ]);
        }),
    ]),
  );
}

class DramaBosEpisodesScreen extends StatefulWidget {
  final DramaProvider provider;
  final DramaItem drama;
  const DramaBosEpisodesScreen({
    super.key, required this.provider, required this.drama,
  });
  @override
  State<DramaBosEpisodesScreen> createState() => _DramaBosEpisodesScreenState();
}
class _DramaBosEpisodesScreenState extends State<DramaBosEpisodesScreen> {
  late final Future<List<DramaEpisode>> episodes =
      DramaBosApi.episodes(widget.provider, widget.drama);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.drama.title)),
    body: FutureBuilder<List<DramaEpisode>>(future: episodes, builder: (context, snap) {
      if (snap.hasError) {
        return Center(child: Padding(padding: const EdgeInsets.all(16),
          child: Text('Erro ao carregar episódios: ' + snap.error.toString())));
      }
      if (!snap.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Episódios consultados pela DramaBos. '
          'A reprodução requer uma fonte com autorização de transmissão.'),
        const SizedBox(height: 12),
        for (final episode in snap.data!) ListTile(
          leading: CircleAvatar(child: Text(episode.number.toString())),
          title: Text(episode.title),
          subtitle: Text(episode.locked ? 'Bloqueado' :
            'Disponível na fonte — player não habilitado'),
          trailing: Icon(episode.locked ? Icons.lock_outline :
            Icons.info_outline),
        ),
        if (snap.data!.isEmpty) const Text('Nenhum episódio encontrado.'),
      ]);
    }),
  );
}
