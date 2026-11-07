import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DownloadStatus { waiting, downloading, completed, failed, cancelled }

class DownloadTask {
  DownloadTask(this.url, this.fileName);
  final String url, fileName;
  DownloadStatus status = DownloadStatus.waiting;
  int received = 0, total = 0;
  String? error, localPath;
  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
  Map<String, dynamic> toJson() => {'url': url, 'fileName': fileName, 'status': status.name, 'localPath': localPath};
  static DownloadTask? fromJson(dynamic v) {
    if (v is! Map) return null;
    final u = v['url']?.toString() ?? '', n = v['fileName']?.toString() ?? '';
    return isDirectMediaUrl(u) && n.isNotEmpty ? DownloadTask(u, n) : null;
  }
}

bool isDirectMediaUrl(String value) {
  final u = Uri.tryParse(value);
  if (u == null || u.scheme != 'https' || u.host.isEmpty) return false;
  final p = u.path.toLowerCase();
  if (p.endsWith('.m3u8') || p.endsWith('.mpd') || p.contains('license') || p.contains('widevine') || p.contains('drm') || p.contains('/key/')) return false;
  return const ['.mp4', '.webm', '.mov', '.m4v', '.mp3', '.m4a', '.aac', '.ogg'].any(p.endsWith);
}

String safeMediaFileName(String url) {
  final u = Uri.parse(url);
  var n = u.pathSegments.isEmpty ? 'midia.mp4' : Uri.decodeComponent(u.pathSegments.last);
  n = n.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return n.isEmpty ? 'midia.mp4' : n;
}

class DownloadQueue extends ChangeNotifier {
  DownloadQueue._();
  static final instance = DownloadQueue._();
  final List<DownloadTask> tasks = [];
  bool _running = false;
  http.Client? _client;

  int get waitingCount => tasks.where((t) => t.status == DownloadStatus.waiting).length;
  int get activeCount => tasks.where((t) => t.status == DownloadStatus.downloading).length;

  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    for (final raw in p.getStringList('novelplay_download_queue_v1') ?? <String>[]) {
      try {
        final t = DownloadTask.fromJson(jsonDecode(raw));
        if (t != null && !tasks.any((x) => x.url == t.url)) tasks.add(t);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<bool> add(String url) async {
    if (!isDirectMediaUrl(url)) return false;
    if (!tasks.any((t) => t.url == url)) {
      tasks.add(DownloadTask(url, safeMediaFileName(url)));
      await _save();
      notifyListeners();
      _pump();
    }
    return true;
  }

  Future<void> remove(DownloadTask t) async {
    if (t.status == DownloadStatus.downloading) {
      t.status = DownloadStatus.cancelled;
      _client?.close();
    }
    tasks.remove(t);
    await _save();
    notifyListeners();
  }

  Future<void> retry(DownloadTask t) async {
    if (t.status == DownloadStatus.failed || t.status == DownloadStatus.cancelled) {
      t.status = DownloadStatus.waiting;
      t.error = null;
      t.received = 0;
      t.total = 0;
      await _save();
      notifyListeners();
      _pump();
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('novelplay_download_queue_v1', tasks.map((t) => jsonEncode(t.toJson())).toList());
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final i = tasks.indexWhere((t) => t.status == DownloadStatus.waiting);
        if (i < 0) break;
        await _download(tasks[i]);
      }
    } finally {
      _client = null;
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _download(DownloadTask t) async {
    final c = http.Client();
    _client = c;
    File? file;
    IOSink? sink;
    try {
      t.status = DownloadStatus.downloading;
      t.received = 0;
      t.error = null;
      notifyListeners();
      final res = await c.send(http.Request('GET', Uri.parse(t.url)));
      if (res.statusCode < 200 || res.statusCode >= 300) throw HttpException('HTTP ' + res.statusCode.toString());
      final type = (res.headers['content-type'] ?? '').toLowerCase();
      if (type.contains('mpegurl') || type.contains('dash+xml')) throw const FormatException('Manifesto de streaming não é arquivo direto.');
      t.total = res.contentLength ?? 0;
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(dir.path + '/NovelPlayDownloads');
      if (!await folder.exists()) await folder.create(recursive: true);
      var name = t.fileName;
      file = File(folder.path + '/' + name);
      var suffix = 1;
      while (await file.exists()) {
        final dot = t.fileName.lastIndexOf('.');
        name = dot > 0 ? t.fileName.substring(0, dot) + ' (' + suffix.toString() + ')' + t.fileName.substring(dot) : t.fileName + ' (' + suffix.toString() + ')';
        file = File(folder.path + '/' + name);
        suffix++;
      }
      sink = file.openWrite();
      await for (final chunk in res.stream) {
        if (t.status == DownloadStatus.cancelled) throw const HttpException('Cancelado');
        sink.add(chunk);
        t.received += chunk.length;
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (t.status == DownloadStatus.cancelled) {
        if (await file.exists()) await file.delete();
      } else {
        t.status = DownloadStatus.completed;
        t.localPath = file.path;
      }
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      if (file != null && await file.exists()) { try { await file.delete(); } catch (_) {} }
      if (t.status != DownloadStatus.cancelled) {
        t.status = DownloadStatus.failed;
        t.error = e.toString().replaceFirst('Exception: ', '');
      }
    } finally {
      c.close();
      if (identical(_client, c)) _client = null;
      await _save();
      notifyListeners();
    }
  }
}

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});
  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  final queue = DownloadQueue.instance;
  final url = TextEditingController();
  @override
  void initState() { super.initState(); queue.restore(); }
  @override
  void dispose() { url.dispose(); super.dispose(); }

  Future<void> _add() async {
    if (!await queue.add(url.text.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Use um link HTTPS direto de arquivo MP4, WebM, MP3 ou compatível.')));
      return;
    }
    url.clear();
  }

  String _label(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.waiting: return 'Na fila';
      case DownloadStatus.downloading: return 'Baixando';
      case DownloadStatus.completed: return 'Concluído';
      case DownloadStatus.failed: return 'Falhou: ' + (t.error ?? 'erro');
      case DownloadStatus.cancelled: return 'Cancelado';
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Downloads')),
    body: AnimatedBuilder(animation: queue, builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.radar, color: Color(0xffff6b9d)), SizedBox(width: 8), Text('Detecção automática', style: TextStyle(fontWeight: FontWeight.bold))]),
        const SizedBox(height: 8),
        const Text('Links diretos de mídia encontrados no navegador aparecerão aqui para você adicionar à fila.'),
        const SizedBox(height: 8),
        Text(queue.waitingCount.toString() + ' aguardando • ' + queue.activeCount.toString() + ' ativo(s)', style: const TextStyle(color: Color(0xffff6b9d))),
      ]))),
      const SizedBox(height: 12),
      const Text('Adicionar link autorizado', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(controller: url, keyboardType: TextInputType.url, decoration: InputDecoration(hintText: 'https://servidor/video.mp4', suffixIcon: IconButton(onPressed: _add, icon: const Icon(Icons.add_circle))), onSubmitted: (_) => _add()),
      const SizedBox(height: 18),
      const Text('Fila de downloads', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      if (queue.tasks.isEmpty) const Padding(padding: EdgeInsets.all(36), child: Center(child: Column(children: [Icon(Icons.download_for_offline_outlined, size: 48, color: Colors.white38), SizedBox(height: 10), Text('Nenhum download na fila')]))),
      for (final t in queue.tasks.reversed)
        Card(child: ListTile(
          leading: Icon(t.status == DownloadStatus.completed ? Icons.check_circle : t.status == DownloadStatus.failed ? Icons.error_outline : t.status == DownloadStatus.downloading ? Icons.downloading : Icons.movie_outlined, color: const Color(0xffff6b9d)),
          title: Text(t.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_label(t), maxLines: 2, overflow: TextOverflow.ellipsis),
            if (t.status == DownloadStatus.downloading) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: t.total > 0 ? t.progress : null),
              if (t.total > 0) Text((t.progress * 100).toStringAsFixed(0) + '% • ' + (t.received / 1048576).toStringAsFixed(1) + ' / ' + (t.total / 1048576).toStringAsFixed(1) + ' MB', style: const TextStyle(fontSize: 11)),
            ],
            if (t.localPath != null) const Text('Salvo na pasta interna do NovelPlay', style: TextStyle(fontSize: 11)),
          ]),
          trailing: t.status == DownloadStatus.failed || t.status == DownloadStatus.cancelled ? IconButton(onPressed: () => queue.retry(t), icon: const Icon(Icons.refresh), tooltip: 'Tentar novamente') : IconButton(onPressed: () => queue.remove(t), icon: const Icon(Icons.close), tooltip: 'Remover'),
        )),
      const SizedBox(height: 12),
      const Text('Somente arquivos diretos HTTPS. Manifestos HLS/DASH, links blob e conteúdo protegido por DRM não são baixados.', style: TextStyle(fontSize: 12, color: Colors.white54)),
    ])),
  );
}
