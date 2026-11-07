import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'download_manager.dart';

/// Official-site WebView with detection of public direct-media URLs only.
class ReelShortPage extends StatefulWidget {
  final Uri url;
  final String title;
  const ReelShortPage({super.key, required this.url, required this.title});

  static Uri? movieUrl(String slug, String id) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(slug) ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) return null;
    return Uri.https('www.reelshort.com', '/id/movie/$slug-$id');
  }

  @override
  State<ReelShortPage> createState() => _ReelShortPageState();
}

class _ReelShortPageState extends State<ReelShortPage> {
  late final WebViewController controller;
  int progress = 0;
  String? error;
  final Set<String> detectedMedia = <String>{};

  static const String _detectorScript = r'''
    (function () {
      if (window.__novelPlayDetectorStarted) return;
      window.__novelPlayDetectorStarted = true;
      function report(value) {
        try {
          if (!value || typeof value !== 'string') return;
          if (/^https:\/\/[^ ]+\.(mp4|webm|mov|m4v|mp3|m4a|aac|ogg)(\?|#|$)/i.test(value)) {
            NovelPlayMedia.postMessage(value);
          }
        } catch (_) {}
      }
      function scan() {
        try {
          document.querySelectorAll('video, audio, source').forEach(function (node) {
            report(node.currentSrc || node.src || node.getAttribute('src'));
          });
          performance.getEntriesByType('resource').forEach(function (entry) {
            report(entry.name);
          });
        } catch (_) {}
      }
      scan();
      window.setInterval(scan, 1800);
      document.addEventListener('loadedmetadata', scan, true);
      document.addEventListener('play', scan, true);
    })();
  ''';

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('NovelPlayMedia', onMessageReceived: (message) {
        final value = message.message.trim();
        if (!isDirectMediaUrl(value) || detectedMedia.contains(value)) return;
        if (mounted) setState(() => detectedMedia.add(value));
      })
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) { if (mounted) setState(() => progress = value); },
        onPageStarted: (_) { if (mounted) setState(() => error = null); },
        onPageFinished: (_) async {
          try { await controller.runJavaScript(_detectorScript); } catch (_) {}
        },
        onWebResourceError: (failure) {
          if (failure.isForMainFrame == true && mounted) setState(() => error = failure.description);
        },
        onNavigationRequest: (request) {
          final next = Uri.tryParse(request.url);
          if (next == null || (next.scheme != 'https' && next.scheme != 'about')) return NavigationDecision.prevent;
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(widget.url);
  }

  Future<void> _showDetected() async {
    if (detectedMedia.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ainda não foi detectado nenhum arquivo direto compatível.')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.65,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const Expanded(child: Text('Mídias detectadas', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                Text(detectedMedia.length.toString()),
              ]),
            ),
            const Divider(height: 1),
            Expanded(child: ListView(children: detectedMedia.map((mediaUrl) {
              final uri = Uri.parse(mediaUrl);
              return ListTile(
                leading: const Icon(Icons.video_file_outlined, color: Color(0xffff6b9d)),
                title: Text(safeMediaFileName(mediaUrl), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(uri.host, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Adicionar à fila',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () async {
                    final added = await DownloadQueue.instance.add(mediaUrl);
                    if (!sheetContext.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added ? 'Arquivo adicionado à fila.' : 'Endereço incompatível.')));
                  },
                ),
              );
            }).toList())),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Mídias detectadas',
          onPressed: _showDetected,
          icon: Badge(isLabelVisible: detectedMedia.isNotEmpty, label: Text(detectedMedia.length.toString()), child: const Icon(Icons.radar)),
        ),
        IconButton(
          tooltip: 'Fila de downloads',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadManagerScreen())),
          icon: const Icon(Icons.download_for_offline_outlined),
        ),
        IconButton(
          tooltip: 'Copiar link oficial',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.url.toString()));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link oficial copiado.')));
          },
          icon: const Icon(Icons.copy),
        ),
        IconButton(tooltip: 'Recarregar página', onPressed: () => controller.reload(), icon: const Icon(Icons.refresh)),
      ],
    ),
    body: Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text('Página oficial. Arquivos diretos detectados: ' + detectedMedia.length.toString() + '. Conteúdo premium e protegido continua sob controle do serviço.',
          style: const TextStyle(fontSize: 12)),
      ),
      if (progress < 100) LinearProgressIndicator(value: progress / 100),
      Expanded(child: error == null ? WebViewWidget(controller: controller) : Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('A página não carregou: $error', textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton(onPressed: () => controller.loadRequest(widget.url), child: const Text('Tentar novamente')),
          const SizedBox(height: 12),
          const Text('Se a reprodução não funcionar na janela integrada, copie o link e abra no navegador.', textAlign: TextAlign.center),
        ])),
      )),
    ]),
  );
}
