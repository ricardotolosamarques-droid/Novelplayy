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
  String? _error, _metadataStatus, _uploadStatus;
  List<Map<String, dynamic>> _metadataCandidates = [];
  List<Map<String, dynamic>> _driveJobs = [];
  bool _driveJobsBusy = false;
  @override
  void initState() { super.initState(); _loadQueue(); _loadDriveJobs(); }
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
    final queryName = uri.queryParameters['filename'] ??
        uri.queryParameters['file'] ??
        uri.queryParameters['name'] ??
        uri.queryParameters['title'];
    final raw = (queryName != null && queryName.trim().isNotEmpty)
        ? queryName
        : (uri.pathSegments.isEmpty ? '' : uri.pathSegments.last);
    if (raw.isEmpty) return 'Novelinha importada';
    final name = raw
      .replaceAll(RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false), '')
      .replaceAll(RegExp(r'(?:ep(?:is[oó]dio|isode)?)[ _.-]*\d+|(?:^|[ _.-])\d{1,4}(?:[ _.-]|$)', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[_-]+'), ' ').trim();
    final technicalName = RegExp(r'^(?:(?:h264|h265|hd|fhd|sd|narrow|wide)(?:\s+|$))+$', caseSensitive: false).hasMatch(name);
    if (name.isEmpty || technicalName || RegExp(r'^[a-f0-9]{20,}$', caseSensitive: false).hasMatch(name.replaceAll(' ', ''))) return 'Novelinha importada';
    return name;
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
    if (query.isEmpty || query.toLowerCase() == 'novelinha' || query.toLowerCase() == 'novelinha importada') {
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

  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<void> _loadDriveJobs() async {
    if (mounted) setState(() => _driveJobsBusy = true);
    try {
      final token = await _getToken();
      if (token == null) return;
      final response = await http.get(
        Uri.parse('$_api/admin/catalog/import-jobs'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 20));
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode != 200) {
        throw Exception(data is Map ? (data['error'] ?? 'Falha ao consultar envios') : 'Falha ao consultar envios');
      }
      final jobs = data is Map && data['jobs'] is List
          ? (data['jobs'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      if (mounted) setState(() => _driveJobs = jobs);
    } catch (e) {
      if (mounted) setState(() => _error = 'Não consegui consultar os envios anteriores: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _driveJobsBusy = false);
    }
  }

  Future<void> _retryDriveJob(String jobId) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; _uploadStatus = 'Preparando a retomada do envio...'; });
    try {
      final token = await _getToken();
      if (token == null) throw Exception('Sua sessão expirou. Entre novamente.');
      final response = await http.post(
        Uri.parse('$_api/admin/catalog/import-jobs/$jobId/retry'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data['error'] ?? 'Não foi possível retomar o envio.');
      }
      if (data['retried'] == false) {
        await _loadDriveJobs();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Todos os episódios desse envio já estão no Google Drive.')));
        return;
      }
      final result = await _waitForUpload(token, jobId);
      await _loadDriveJobs();
      if (!mounted) return;
      final uploaded = (result['uploaded'] as num?)?.toInt() ?? 0;
      final failed = (result['failed'] as num?)?.toInt() ?? 0;
      final total = (result['total'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed == 0
          ? '$uploaded de $total episódios salvos no Google Drive.'
          : '$uploaded de $total salvos; $failed ainda falharam.'),
        duration: const Duration(seconds: 7),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      await _loadDriveJobs();
    } finally {
      if (mounted) setState(() { _busy = false; _uploadStatus = null; });
    }
  }

  Future<Map<String, dynamic>> _waitForUpload(String token, String jobId) async {
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (DateTime.now().isBefore(deadline)) {
      final response = await http.get(
        Uri.parse('$_api/admin/catalog/import-jobs/$jobId'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 20));
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data['error'] ?? 'Não foi possível consultar o envio ao Drive.');
      }
      final status = (data['status'] ?? '').toString();
      final uploaded = data['uploaded'] ?? 0;
      final failed = data['failed'] ?? 0;
      final total = data['total'] ?? 0;
      if (mounted) setState(() => _uploadStatus = 'Enviando para o Drive: ' + (uploaded + failed).toString() + ' de ' + total.toString() + ' episódios processados.');
      if (status == 'completed' || status == 'completed_with_errors' || status == 'failed') return data;
      await Future.delayed(const Duration(seconds: 3));
    }
    throw Exception('O envio continua no servidor, mas demorou mais que o esperado. Você pode voltar ao catálogo; a transferência continuará em segundo plano.');
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
    setState(() { _busy = true; _error = null; _uploadStatus = 'Preparando os episódios para envio...'; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);
      if (token == null) throw Exception('Sua sessão expirou. Entre novamente.');
      final response = await http.post(Uri.parse('$_api/admin/catalog/import-links'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({'title': _title.text.trim(), 'synopsis': _synopsis.text.trim(),
          'coverUrl': _cover.text.trim(), 'authorizedPlayback': true, 'episodes': episodes}))
        .timeout(const Duration(seconds: 45));
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data['error'] ?? 'Falha ao iniciar importação (HTTP ' + response.statusCode.toString() + ').');
      }
      final duplicateCount = (data['duplicateCount'] as num?)?.toInt() ?? 0;
      if (data['duplicateOnly'] == true) {
        await prefs.remove(_queueKey);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$duplicateCount link(s) já estavam cadastrados. Nenhum episódio foi enviado novamente.'),
          duration: const Duration(seconds: 6),
        ));
        Navigator.pop(context, true);
        return;
      }
      final jobId = (data['jobId'] ?? '').toString();
      if (jobId.isEmpty) throw Exception('O servidor não retornou o identificador do envio ao Drive.');
      final result = await _waitForUpload(token, jobId);
      await prefs.remove(_queueKey);
      if (!mounted) return;
      final uploaded = result['uploaded'] ?? 0;
      final failed = result['failed'] ?? 0;
      final total = result['total'] ?? episodes.length;
      final duplicateMessage = duplicateCount > 0 ? ' $duplicateCount link(s) repetido(s) foram ignorados.' : '';
      final message = (failed == 0
        ? uploaded.toString() + ' de ' + total.toString() + ' episódios salvos no Google Drive.'
        : uploaded.toString() + ' de ' + total.toString() + ' salvos no Drive; ' + failed.toString() + ' falharam. Verifique se os links são downloads diretos e não exigem login.') + duplicateMessage;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 7)));
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() { _busy = false; _uploadStatus = null; }); }
  }
  @override
  void dispose() { _title.dispose(); _synopsis.dispose(); _cover.dispose(); _links.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Importar do 1DM')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      const Text('No 1DM, use Compartilhar e escolha NovelPlay. Você também pode colar vários links de uma vez.', style: TextStyle(color: Colors.white70)),
      if (_driveJobsBusy || _driveJobs.isNotEmpty) ...[
        Row(children: [
          const Expanded(child: Text('Envios anteriores ao Google Drive', style: TextStyle(fontWeight: FontWeight.bold))),
          IconButton(onPressed: _driveJobsBusy ? null : _loadDriveJobs, icon: const Icon(Icons.refresh), tooltip: 'Atualizar envios'),
        ]),
        if (_driveJobsBusy) const LinearProgressIndicator(),
        for (final job in _driveJobs)
          Card(
            child: ListTile(
              title: Text((job['title'] ?? 'Novelinha').toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${job['uploaded'] ?? 0} enviados • ${job['failed'] ?? 0} falharam • ${job['pending'] ?? 0} pendentes de ${job['total'] ?? 0}'),
              trailing: ((job['failed'] as num?) ?? 0) > 0 || (job['status'] == 'failed')
                ? TextButton(
                    onPressed: _busy ? null : () => _retryDriveJob((job['jobId'] ?? '').toString()),
                    child: const Text('Tentar novamente'),
                  )
                : const Icon(Icons.sync, size: 20),
            ),
          ),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 18),
      TextField(controller: _title, onSubmitted: (_) => _lookupMetadata(), decoration: InputDecoration(labelText: 'Nome da novelinha', suffixIcon: IconButton(onPressed: _metadataBusy ? null : _lookupMetadata, icon: const Icon(Icons.search), tooltip: 'Buscar capa e sinopse'))),
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
      TextField(controller: _links, minLines: 7, maxLines: 12, decoration: const InputDecoration(labelText: 'Links dos episódios', hintText: 'Um link HTTPS por linha'), onChanged: (_) { _suggestTitle(); setState(() {}); SharedPreferences.getInstance().then((prefs) => prefs.setString(_queueKey, _links.text)); }),
      const SizedBox(height: 8),
      Text('${_extractLinks().length} links válidos • numeração automática', style: const TextStyle(color: Colors.white70, fontSize: 12)),
      CheckboxListTile(contentPadding: EdgeInsets.zero, value: _authorized, onChanged: (v) => setState(() => _authorized = v ?? false), title: const Text('Tenho autorização para reproduzir e distribuir estes vídeos.'), controlAffinity: ListTileControlAffinity.leading),
      if (_uploadStatus != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_uploadStatus!, style: const TextStyle(color: Colors.white70))),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
      FilledButton.icon(onPressed: _busy ? null : _import, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_upload_outlined), label: Text(_busy ? 'Enviando para o Google Drive...' : 'Enviar ${_extractLinks().length} episódios para o Drive')),
    ]),
  );
}
