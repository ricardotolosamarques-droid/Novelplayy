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
  bool _authorized = false, _busy = false;
  String? _error;
  @override
  void initState() { super.initState(); _loadQueue(); }
  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    _links.text = prefs.getString(_queueKey) ?? '';
    _suggestTitle();
    if (mounted) setState(() {});
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
      TextField(controller: _cover, decoration: const InputDecoration(labelText: 'URL HTTPS da capa (opcional)')),
      const SizedBox(height: 12),
      TextField(controller: _links, minLines: 7, maxLines: 12, decoration: const InputDecoration(labelText: 'Links dos episódios', hintText: 'Um link HTTPS por linha'), onChanged: (_) { _suggestTitle(); setState(() {}); }),
      const SizedBox(height: 8),
      Text('${_extractLinks().length} links válidos • numeração automática', style: const TextStyle(color: Colors.white70, fontSize: 12)),
      CheckboxListTile(contentPadding: EdgeInsets.zero, value: _authorized, onChanged: (v) => setState(() => _authorized = v ?? false), title: const Text('Tenho autorização para reproduzir e distribuir estes vídeos.'), controlAffinity: ListTileControlAffinity.leading),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
      FilledButton.icon(onPressed: _busy ? null : _import, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_upload_outlined), label: Text(_busy ? 'Importando...' : 'Importar ${_extractLinks().length} episódios')),
    ]),
  );
}
