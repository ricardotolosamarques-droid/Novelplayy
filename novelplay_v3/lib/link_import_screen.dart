import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
const _api = 'https://novelplay-api-ee5f.onrender.com';
const _tokenKey = 'novelplay_auth_token';
const _queueKey = 'novelplay_pending_shared_links';

class LinkImportScreen extends StatefulWidget {
  const LinkImportScreen({super.key});
  @override
  State<LinkImportScreen> createState() => _LinkImportScreenState();
}
class _LinkImportScreenState extends State<LinkImportScreen> {
  final _title = TextEditingController(), _synopsis = TextEditingController(), _cover = TextEditingController(), _links = TextEditingController();
  bool _authorized = false, _busy = false, _metadataBusy = false;
  String? _error, _metadataStatus;
  List<Map<String, dynamic>> _metadataCandidates = [];
  @override
  void initState() { super.initState(); _loadQueue(); }
  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    _links.text = prefs.getString(_queueKey) ?? '';
    _suggestTitle();
    if (mounted) setState(() {});
    await _lookupMetadata();
  }
  List<Uri> _extractLinks() {
    final seen = <String>{};
    return RegExp(r'https?://[^\s<>"\x27]+', caseSensitive: false).allMatches(_links.text)
      .map((m) => m.group(0)!.replaceAll(RegExp(r'[),.;]+$'), ''))
      .map(Uri.tryParse).whereType<Uri>()
      .where((u) => u.scheme == 'https' && u.host.isNotEmpty && u.userInfo.isEmpty && seen.add(u.toString())).toList();
  }
  int _episodeNumber(Uri uri, int fallback) {
    final name = Uri.decodeComponent(uri.pathSegments.isEmpty ? '' : uri.pathSegments.last);
    final m = RegExp(r'(?:ep(?:is[oó]dio|isode)?)[ _.-]*(\d+)|(?:^|[ _.-])(\d{1,4})(?:[ _.-]|$)', caseSensitive: false).firstMatch(name);
    return int.tryParse(m?.group(1) ?? m?.group(2) ?? '') ?? fallback;
  }
  String _suggestedName(Uri uri) {
    if (uri.pathSegments.isEmpty) return 'Novelinha';
    final name = Uri.decodeComponent(uri.pathSegments.last)
      .replaceAll(RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false), '')
      .replaceAll(RegExp(r'(?:ep(?:is[oó]dio|isode)?)[ _.-]*\d+|(?:^|[ _.-])\d{1,4}(?:[ _.-]|$)', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[_-]+'), ' ').trim();
    return name.isEmpty ? 'Novelinha importada' : name;
  }
  void _suggestTitle() {
    final links = _extractLinks();
    if (links.isNotEmpty && _title.text.trim().isEmpty) _title.text = _suggestedName(links.first);
  }

  String _normalizeTitle(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

  Future<void> _lookupMetadata() async {
    final query = _title.text.trim();
    if (query.isEmpty || query.toLowerCase() == 'novelinha') {
      if (mounted) setState(() => _metadataStatus = 'Não consegui identificar o título pelo link. Informe o nome para pesquisar automaticamente.');
      return;
    }
    if (mounted) setState(() { _metadataBusy = true; _metadataStatus = 'Buscando capa e sinopse...'; _metadataCandidates = []; });
    try {
      final uri = Uri.parse('$_api/reelshort/search').replace(queryParameters: {'keywords': query});
      final response = await http.get(uri, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw Exception('Pesquisa de catálogo indisponível (HTTP ${response.statusCode}).');
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final results = data is Map && data['results'] is List
        ? (data['results'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((e) => (e['book_title'] ?? '').toString().trim().isNotEmpty).toList()
        : <Map<String, dynamic>>[];
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() => _metadataStatus = 'Não encontrei uma correspondência segura. Você pode revisar o nome e pesquisar novamente.');
        return;
      }
      final normalized = _normalizeTitle(query);
      final exact = results.where((e) => _normalizeTitle((e['book_title'] ?? '').toString()) == normalized).toList();
      if (exact.length == 1) {
        _applyMetadata(exact.first);
        setState(() => _metadataStatus = 'Capa e sinopse encontradas automaticamente.');
      } else {
        setState(() {
          _metadataCandidates = results.take(8).toList();
          _metadataStatus = 'Encontrei possíveis correspondências. Escolha a novelinha correta para preencher capa e sinopse.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _metadataStatus = 'Não foi possível pesquisar agora. ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _metadataBusy = false);
    }
  }

  void _applyMetadata(Map<String, dynamic> item) {
    final title = (item['book_title'] ?? '').toString().trim();
    final synopsis = (item['special_desc'] ?? '').toString().trim();
    final cover = (item['book_pic'] ?? '').toString().trim();
    if (title.isNotEmpty) _title.text = title;
    if (synopsis.isNotEmpty) _synopsis.text = synopsis;
    if (cover.startsWith('https://')) _cover.text = cover;
    _metadataCandidates = [];
  }

  Future<void> _import() async {
    final links = _extractLinks();
    if (_title.text.trim().isEmpty) { setState(() => _error = 'Informe o nome da novelinha.'); return; }
    if (links.isEmpty) { setState(() => _error = 'Não encontrei links HTTPS válidos.'); return; }
    if (!_authorized) { setState(() => _error = 'Confirme que possui autorização para reproduzir e distribuir estes vídeos.'); return; }
    final used = <int>{};
    final episodes = <Map<String, dynamic>>[];
    for (var i = 0; i < links.length; i++) {
      var number = _episodeNumber(links[i], i + 1);
      while (!used.add(number)) { number++; }
      episodes.add({'number': number, 'title': 'Episódio $number', 'videoUrl': links[i].toString()});
    }
    setState(() { _busy = true; _error = null; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      if (token == null) throw Exception('Sua sessão expirou. Entre novamente.');
      final response = await http.post(Uri.parse('$_api/admin/catalog/import-links'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({'title': _title.text.trim(), 'synopsis': _synopsis.text.trim(),
          'coverUrl': _cover.text.trim(), 'authorizedPlayback': true, 'episodes': episodes}))
        .timeout(const Duration(seconds: 45));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data['error'] ?? 'Falha ao importar (HTTP ${response.statusCode}).');
      }
      await prefs.remove(_queueKey);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${data['episodeCount'] ?? episodes.length} episódios importados.')));
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  void dispose() { _title.dispose(); _synopsis.dispose(); _cover.dispose(); _links.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Importar do 1DM')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      const Text('No 1DM, use Compartilhar e escolha NovelPlay. Você também pode colar vários links de uma vez.', style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 18),
      TextField(controller: _title, decoration: const InputDecoration(labelText: 'Nome da novelinha')),
      const SizedBox(height: 12),
      TextField(controller: _synopsis, maxLines: 2, decoration: const InputDecoration(labelText: 'Sinopse (opcional)')),
      const SizedBox(height: 12),
      TextField(controller: _cover, decoration: const InputDecoration(labelText: 'Capa (preenchida automaticamente quando encontrada)')),
      if (_cover.text.trim().startsWith('https://'))
        Padding(padding: const EdgeInsets.only(top: 8), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(_cover.text.trim(), height: 150, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const SizedBox.shrink()))),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text(_metadataStatus ?? 'O NovelPlay tentará localizar os dados da novelinha.', style: const TextStyle(color: Colors.white70, fontSize: 12))),
        IconButton(onPressed: _metadataBusy ? null : _lookupMetadata, tooltip: 'Pesquisar capa e sinopse', icon: _metadataBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome)),
      ]),
      for (final item in _metadataCandidates)
        Card(child: ListTile(
          leading: (item['book_pic'] ?? '').toString().startsWith('https://')
            ? Image.network(item['book_pic'].toString(), width: 44, height: 60, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.movie))
            : const Icon(Icons.movie),
          title: Text((item['book_title'] ?? 'Novelinha').toString()),
          subtitle: Text((item['special_desc'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.check_circle_outline),
          onTap: () => setState(() { _applyMetadata(item); _metadataStatus = 'Dados preenchidos. Confira antes de publicar.'; }),
        )),
      const SizedBox(height: 12),
      TextField(controller: _links, minLines: 7, maxLines: 12, decoration: const InputDecoration(labelText: 'Links dos episódios', hintText: 'Um link HTTPS por linha'), onChanged: (_) { _suggestTitle(); setState(() {}); }),
      const SizedBox(height: 8),
      Text('${_extractLinks().length} links válidos • numeração automática', style: const TextStyle(color: Colors.white70, fontSize: 12)),
      CheckboxListTile(contentPadding: EdgeInsets.zero, value: _authorized, onChanged: (v) => setState(() => _authorized = v ?? false), title: const Text('Tenho autorização para reproduzir e distribuir estes vídeos.'), controlAffinity: ListTileControlAffinity.leading),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
      FilledButton.icon(onPressed: _busy ? null : _import, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_upload_outlined), label: Text(_busy ? 'Publicando...' : 'Confirmar e publicar ${_extractLinks().length} episódios')),
    ]),
  );
}
