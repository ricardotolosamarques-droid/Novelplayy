import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Opens the official ReelShort website within the NovelPlay application.
/// Does not access third-party HLS URLs, inject scripts, or bypass subscriptions.
class ReelShortPage extends StatefulWidget {
  final Uri url;
  final String title;

  const ReelShortPage({super.key, required this.url, required this.title});

  static Uri? movieUrl(String slug, String id) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(slug) ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      return null;
    }
    return Uri.https('www.reelshort.com', '/id/movie/$slug-$id');
  }

  @override
  State<ReelShortPage> createState() => _ReelShortPageState();
}

class _ReelShortPageState extends State<ReelShortPage> {
  late final WebViewController controller;
  int progress = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => progress = value);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => error = null);
          },
          onWebResourceError: (failure) {
            if (failure.isForMainFrame == true && mounted) {
              setState(() => error = failure.description);
            }
          },
          onNavigationRequest: (request) {
            final next = Uri.tryParse(request.url);
            if (next == null ||
                (next.scheme != 'https' && next.scheme != 'about')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Copiar link oficial',
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: widget.url.toString()),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link oficial copiado.')),
              );
            },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Recarregar página',
            onPressed: () => controller.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Página oficial ReelShort. A disponibilidade e o acesso '
              'a episódios premium são controlados pelo ReelShort.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (progress < 100)
            LinearProgressIndicator(value: progress / 100),
          Expanded(
            child: error == null
                ? WebViewWidget(controller: controller)
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('A página não carregou: $error',
                              textAlign: TextAlign.center),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: () =>
                                controller.loadRequest(widget.url),
                            child: const Text('Tentar novamente'),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Se a reprodução não funcionar na janela '
                            'integrada, copie o link e abra no navegador.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
