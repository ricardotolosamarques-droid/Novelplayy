import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'drive_screen.dart';
import 'link_import_screen.dart';

const String _authBaseUrl = 'https://novelplay-api-ee5f.onrender.com';

class NovelUser {
  final String id, username, email, role;
  const NovelUser({required this.id, required this.username, required this.email, required this.role});
  factory NovelUser.fromJson(Map<String, dynamic> json) => NovelUser(
    id: '${json['id'] ?? ''}', username: '${json['username'] ?? ''}',
    email: '${json['email'] ?? ''}', role: '${json['role'] ?? 'user'}',
  );
  bool get isAdmin => role == 'admin';
}

class _AuthHttpException implements Exception {
  final int statusCode;
  final String message;
  const _AuthHttpException(this.statusCode, this.message);
  @override String toString() => message;
}

class NovelAuth {
  static const _tokenKey = 'novelplay_auth_token';
  static const _userKey = 'novelplay_auth_user';
  static Future<String?> token() async => (await SharedPreferences.getInstance()).getString(_tokenKey);
  static Future<void> saveSession(String value, NovelUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, value);
    await prefs.setString(_userKey, jsonEncode({
      'id': user.id, 'username': user.username, 'email': user.email, 'role': user.role,
    }));
  }
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }
  static Future<NovelUser?> _cachedUser() async {
    final raw = (await SharedPreferences.getInstance()).getString(_userKey);
    if (raw == null) return null;
    try { return NovelUser.fromJson(jsonDecode(raw) as Map<String, dynamic>); }
    catch (_) { return null; }
  }

  static Future<Map<String, dynamic>> _request(String path, {Map<String, dynamic>? body, String? bearer}) async {
    final response = await (body == null
      ? http.get(Uri.parse('$_authBaseUrl$path'), headers: bearer == null ? {} : {'Authorization': 'Bearer $bearer'})
      : http.post(Uri.parse('$_authBaseUrl$path'), headers: {'Content-Type': 'application/json', if (bearer != null) 'Authorization': 'Bearer $bearer'}, body: jsonEncode(body)))
      .timeout(const Duration(seconds: 25));
    Map<String, dynamic> data;
    try { data = jsonDecode(response.body) as Map<String, dynamic>; }
    catch (_) { throw Exception('Resposta inválida do servidor (${response.statusCode}).'); }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _AuthHttpException(response.statusCode,
        '${data['error'] ?? 'Não foi possível concluir a solicitação.'}');
    }
    return data;
  }

  static Future<NovelUser?> restore() async {
    final saved = await token();
    if (saved == null) return null;
    try {
      final data = await _request('/auth/me', bearer: saved);
      final user = NovelUser.fromJson(data['user'] as Map<String, dynamic>);
      await (await SharedPreferences.getInstance()).setString(_userKey, jsonEncode({
        'id': user.id, 'username': user.username, 'email': user.email, 'role': user.role,
      }));
      return user;
    } catch (error) {
      if (error is _AuthHttpException &&
          (error.statusCode == 401 || error.statusCode == 404)) {
        await logout();
        return null;
      }
      return _cachedUser();
    }
  }

  static Future<NovelUser> login(String identity, String password) async {
    final data = await _request('/auth/login', body: {'identity': identity, 'password': password});
    final user = NovelUser.fromJson(data['user'] as Map<String, dynamic>);
    await saveSession(data['token'] as String, user);
    return user;
  }

  static Future<NovelUser> register(String username, String email, String password) async {
    final data = await _request('/auth/register', body: {'username': username, 'email': email, 'password': password});
    final user = NovelUser.fromJson(data['user'] as Map<String, dynamic>);
    await saveSession(data['token'] as String, user);
    return user;
  }

  static Future<List<Map<String, dynamic>>> users() async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    final data = await _request('/admin/users', bearer: saved);
    return (data['users'] as List).cast<Map<String, dynamic>>();
  }
  static Future<List<Map<String, dynamic>>> catalog() async {
    final data = await _request('/catalog');
    return (data['series'] as List? ?? const []).cast<Map<String, dynamic>>();
  }
  static Future<void> createSeries(String title, String synopsis, String coverUrl) async {
    final saved = await token();
    if (saved == null) throw Exception('Sua sessão terminou. Entre novamente.');
    await _request('/admin/catalog/series', bearer: saved, body: {
      'title': title, 'synopsis': synopsis, 'coverUrl': coverUrl,
    });
  }
  static Future<void> addEpisode(String seriesId, int number, String title, String videoUrl) async {
    final saved = await token();
    if (saved == null) throw Exception('Sua sessão terminou. Entre novamente.');
    await _request('/admin/catalog/series/$seriesId/episodes', bearer: saved, body: {
      'number': number, 'title': title, 'videoUrl': videoUrl,
    });
  }

  static Future<Map<String, dynamic>> googleDriveStatus() async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    return _request('/admin/google-drive/status', bearer: saved);
  }

  static Future<String> googleDriveConnectUrl() async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    final data = await _request('/admin/google-drive/connect', bearer: saved);
    final value = data['authorizationUrl'];
    if (value is! String || value.isEmpty) {
      throw Exception('O servidor não retornou o endereço de autorização.');
    }
    return value;
  }

  static Future<Map<String, dynamic>> googleDriveRecoveryPreview() async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    return _request('/admin/google-drive/recovery/preview', bearer: saved);
  }

  static Future<Map<String, dynamic>> startGoogleDriveRecovery(List<String> episodeIds) async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    return _request('/admin/google-drive/recovery', bearer: saved, body: {'episodeIds': episodeIds});
  }

  static Future<Map<String, dynamic>> googleDriveRecoveryJob(String jobId) async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    return _request('/admin/google-drive/recovery/$jobId', bearer: saved);
  }
  static Future<void> deleteSeries(String seriesId) async {
    final saved = await token();
    if (saved == null) throw Exception('Sua sessão terminou. Entre novamente.');
    final response = await http.delete(
      Uri.parse('$_authBaseUrl/admin/catalog/series/$seriesId'),
      headers: {'Authorization': 'Bearer $saved'},
    ).timeout(const Duration(seconds: 25));
    Map<String, dynamic> data;
    try { data = jsonDecode(response.body) as Map<String, dynamic>; }
    catch (_) { throw Exception('Resposta inválida do servidor (${response.statusCode}).'); }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _AuthHttpException(response.statusCode,
        '${data['error'] ?? 'Não foi possível excluir a publicação.'}');
    }
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}
class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  static const MethodChannel _shareChannel = MethodChannel('novelplay/share');
  static const String _pendingLinksKey = 'novelplay_pending_shared_links';
  NovelUser? user;
  bool loading = true;
  Future<void> _shareSaveQueue = Future<void>.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') await _saveSharedText(call.arguments);
    });
    _consumeInitialShare();
    _restore();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _consumeInitialShare();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  Future<void> _consumeInitialShare() async {
    try {
      final value = await _shareChannel.invokeMethod<String>('getInitialSharedText');
      if (value != null) await _saveSharedText(value);
    } catch (_) {}
  }
  Future<void> _saveSharedText(dynamic value) {
    final incoming = (value ?? '').toString().trim();
    if (incoming.isEmpty) return Future<void>.value();
    // Serialize incoming share intents so two quick shares cannot overwrite each other.
    _shareSaveQueue = _shareSaveQueue
        .catchError((_) {})
        .then((_) => _saveSharedTextNow(incoming));
    return _shareSaveQueue;
  }

  Future<void> _saveSharedTextNow(String incoming) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_pendingLinksKey) ?? '';
    // Also split legacy values written with a literal "\n" by the previous version.
    final existing = previous
        .split(RegExp(r'\\n|\s+'))
        .where((item) => item.trim().isNotEmpty)
        .toList();

    String keyFor(String item) {
      final uri = Uri.tryParse(item.trim());
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return item.trim();
      }
      return uri.replace(fragment: '').toString();
    }

    final known = existing.map(keyFor).toSet();
    final added = <String>[];
    var duplicates = 0;
    for (final item in incoming.split(RegExp(r'\s+'))) {
      final candidate = item.trim();
      if (candidate.isEmpty) continue;
      if (!known.add(keyFor(candidate))) {
        duplicates++;
      } else {
        added.add(candidate);
      }
    }

    if (added.isNotEmpty) {
      await prefs.setString(_pendingLinksKey, [...existing, ...added].join('\n'));
    }

    if (mounted) {
      final message = added.isEmpty
          ? 'Este link já está cadastrado na lista de episódios.'
          : duplicates > 0
              ? '${added.length} link(s) adicionado(s). $duplicates repetido(s) já estavam na lista.'
              : 'Links recebidos. Abra Importar do 1DM para revisar os episódios.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
      ));
    }
  }

  Future<void> _restore() async {
    try {
      final restored = await NovelAuth.restore();
      if (!mounted) return;
      setState(() {
        user = restored;
        loading = false;
      });
    } catch (error, stack) {
      // Never leave the app stuck on the splash/loading screen if a native
      // storage plugin fails while restoring the saved session. Re-throw
      // after releasing the UI so the global diagnostic handler can display
      // the full error report on top of the login screen.
      if (mounted) {
        setState(() {
          user = null;
          loading = false;
        });
      }
      Error.throwWithStackTrace(error, stack);
    }
  }
  void _entered(NovelUser value) => setState(() => user = value);
  Future<void> _signOut() async {
    await NovelAuth.logout();
    if (mounted) setState(() => user = null);
  }
  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(backgroundColor: Color(0xff101018), body: Center(child: CircularProgressIndicator()));
    if (user == null) return AuthScreen(onSuccess: _entered);
    return Scaffold(
      backgroundColor: const Color(0xff101018),
      appBar: AppBar(
        title: const Text('NovelPlay'),
        actions: [
          if (user!.isAdmin) IconButton(
            tooltip: 'Painel administrativo', icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminUsersScreen())),
          ),
          if (user!.isAdmin) IconButton(
            tooltip: 'Importar links do 1DM', icon: const Icon(Icons.move_to_inbox_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LinkImportScreen())),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (value) { if (value == 'logout' || value == 'switch') _signOut(); },
            itemBuilder: (_) => [PopupMenuItem(enabled: false, child: Text(user!.username)), const PopupMenuItem(value: 'switch', child: Text('Trocar conta / abrir login')), const PopupMenuItem(value: 'logout', child: Text('Sair da conta'))],
          ),
        ],
      ),
      body: DriveNovelScreen(isAdmin: user!.isAdmin),
    );
  }
}

class AuthScreen extends StatefulWidget {
  final ValueChanged<NovelUser> onSuccess;
  const AuthScreen({super.key, required this.onSuccess});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}
class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController(), _email = TextEditingController(), _password = TextEditingController();
  bool registering = false, busy = false, obscure = true;
  String? error;
  @override
  void dispose() { _username.dispose(); _email.dispose(); _password.dispose(); super.dispose(); }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { busy = true; error = null; });
    try {
      final result = registering
        ? await NovelAuth.register(_username.text.trim(), _email.text.trim(), _password.text)
        : await NovelAuth.login(_email.text.trim(), _password.text);
      if (mounted) widget.onSuccess(result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() => busy = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff101018),
    body: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(26),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Form(
        key: _formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.movie_filter_rounded, color: Color(0xffff6b9d), size: 68),
          const SizedBox(height: 12),
          const Text('NOVELPLAY', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(registering ? 'Crie sua conta para começar' : 'Entre para assistir suas novelinhas', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 30),
          if (registering) ...[
            TextFormField(controller: _username, decoration: const InputDecoration(labelText: 'Nome de usuário', prefixIcon: Icon(Icons.person_outline)), validator: (v) => (v == null || v.trim().length < 3) ? 'Use pelo menos 3 caracteres.' : null),
            const SizedBox(height: 14),
            TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.email_outlined)), validator: (v) => (v == null || !v.contains('@')) ? 'Informe um e-mail válido.' : null),
          ] else
            TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'E-mail ou usuário', prefixIcon: Icon(Icons.person_outline)), validator: (v) => (v == null || v.trim().isEmpty) ? 'Informe seu e-mail ou usuário.' : null),
          const SizedBox(height: 14),
          TextFormField(controller: _password, obscureText: obscure, decoration: InputDecoration(labelText: 'Senha', prefixIcon: const Icon(Icons.lock_outline), suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => obscure = !obscure))), validator: (v) => (v == null || v.length < (registering ? 8 : 1)) ? (registering ? 'A senha precisa ter pelo menos 8 caracteres.' : 'Informe sua senha.') : null),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center)),
          const SizedBox(height: 22),
          FilledButton(onPressed: busy ? null : _submit, style: FilledButton.styleFrom(backgroundColor: const Color(0xffff6b9d), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)), child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : Text(registering ? 'CRIAR CONTA' : 'ENTRAR', style: const TextStyle(fontWeight: FontWeight.w900))),
          TextButton(onPressed: busy ? null : () => setState(() { registering = !registering; error = null; }), child: Text(registering ? 'Já tenho uma conta • Entrar' : 'Ainda não tem conta? Criar conta')),
        ]),
      )),
    )),
  );
}

class GoogleDriveAdminScreen extends StatefulWidget {
  const GoogleDriveAdminScreen({super.key});
  @override
  State<GoogleDriveAdminScreen> createState() => _GoogleDriveAdminScreenState();
}

class _GoogleDriveAdminScreenState extends State<GoogleDriveAdminScreen> {
  bool loading = true, connecting = false, connected = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    setState(() { loading = true; error = null; });
    try {
      final result = await NovelAuth.googleDriveStatus();
      if (!mounted) return;
      setState(() { connected = result['connected'] == true; loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { error = e.toString().replaceFirst('Exception: ', ''); loading = false; });
    }
  }

  Future<void> _connect() async {
    setState(() { connecting = true; error = null; });
    try {
      final url = await NovelAuth.googleDriveConnectUrl();
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened) throw Exception('Não foi possível abrir a página do Google. Tente novamente.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conclua a autorização no Google e volte ao NovelPlay. Depois toque em Verificar conexão.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Icon(Icons.cloud_outlined, size: 64, color: Color(0xffff6b9d)),
      const SizedBox(height: 14),
      const Text('Google Drive', textAlign: TextAlign.center,
        style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('Conecte a conta Google que contém as pastas, capas e vídeos das novelinhas.',
        textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 24),
      Card(
        color: const Color(0xff1b1b27),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Icon(connected ? Icons.check_circle : Icons.info_outline,
              color: connected ? Colors.greenAccent : Colors.orangeAccent),
            const SizedBox(width: 12),
            Expanded(child: Text(
              loading ? 'Verificando conexão...' : connected ? 'Google Drive conectado' : 'Google Drive não conectado',
              style: const TextStyle(fontWeight: FontWeight.w600),
            )),
            if (loading) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
        ),
      ),
      if (error != null) Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
      ),
      const SizedBox(height: 14),
      FilledButton.icon(
        onPressed: connecting ? null : _connect,
        icon: connecting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login),
        label: Text(connecting ? 'Abrindo Google...' : connected ? 'Reconectar Google Drive' : 'Conectar Google Drive'),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xffff6b9d), padding: const EdgeInsets.symmetric(vertical: 15)),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: loading ? null : _checkStatus,
        icon: const Icon(Icons.refresh),
        label: const Text('Verificar conexão'),
      ),
      const SizedBox(height: 18),
      const DriveRecoveryAdminSection(),
      const SizedBox(height: 18),
      const Text('Ao tocar em Reconectar, o Google abrirá uma página para você autorizar o NovelPlay a consultar pastas e enviar vídeos ao Drive. Depois, volte ao app e toque em Verificar conexão.',
        textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, height: 1.4)),
    ],
  );
}


class DriveRecoveryAdminSection extends StatefulWidget {
  const DriveRecoveryAdminSection({super.key});
  @override
  State<DriveRecoveryAdminSection> createState() => _DriveRecoveryAdminSectionState();
}

class _DriveRecoveryAdminSectionState extends State<DriveRecoveryAdminSection> {
  bool loading = false, running = false;
  String? error, progress;
  List<Map<String, dynamic>> items = [];
  final Set<String> selected = {};

  Future<void> _preview() async {
    setState(() { loading = true; error = null; });
    try {
      final data = await NovelAuth.googleDriveRecoveryPreview();
      if (!mounted) return;
      final rows = (data['items'] as List? ?? const []).whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e)).toList();
      setState(() {
        // Mostra somente episódios ainda recuperáveis. Os já recuperados
        // desaparecem da lista após a atualização da prévia.
        items = rows.where((e) => e['hasSourceUrl'] == true &&
          ['not_checked', 'failed'].contains(e['recoveryStatus'])).toList();
        // Toda nova consulta começa sem seleções para evitar lotes acidentais.
        selected.clear();
        loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { error = e.toString(); loading = false; });
    }
  }

  Future<void> _recover() async {
    if (selected.isEmpty || running) return;
    final ids = selected.toList();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Testar recuperação'),
      content: Text('O NovelPlay vai substituir o conteúdo de ${ids.length} arquivo(s) existente(s) no Drive, preservando os links. Para o primeiro teste, selecione apenas um episódio.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmar')),
      ],
    ));
    if (ok != true) return;
    setState(() { running = true; error = null; progress = 'Iniciando...'; });
    try {
      final started = await NovelAuth.startGoogleDriveRecovery(ids);
      final jobId = '${started['jobId']}';
      while (mounted) {
        final state = await NovelAuth.googleDriveRecoveryJob(jobId);
        setState(() => progress = 'Recuperados: ${state['recovered']}/${state['total']} • Falhas: ${state['failed']} • Pendentes: ${state['pending']}');
        if (['completed', 'completed_with_errors', 'failed'].contains(state['status'])) break;
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      if (mounted) await _preview();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xff1b1b27),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Recuperar episódios antigos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text('Procura episódios antigos enviados pelo NovelPlay que ainda têm o link original salvo. Os envios feitos depois da correção de áudio são ignorados. A recuperação atualiza o arquivo existente no Drive, sem criar outra cópia. Teste primeiro com apenas um episódio.',
          style: TextStyle(color: Colors.white70, height: 1.35)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: loading || running ? null : _preview,
          icon: loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search),
          label: Text(loading ? 'Procurando...' : 'Ver episódios recuperáveis'),
        ),
        if (items.isNotEmpty) ...[
          Text('Episódios ainda recuperáveis: ${items.length} • Já recuperados desaparecem desta lista.',
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
          for (final item in items)
            if (item['hasSourceUrl'] == true &&
                ['not_checked', 'failed'].contains(item['recoveryStatus']))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: selected.contains('${item['id']}'),
                onChanged: running ? null : (value) => setState(() {
                  final id = '${item['id']}';
                  if (value == true) {
                    if (selected.length >= 100) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Selecione no máximo 100 episódios por vez.')),
                      );
                    } else {
                      selected.add(id);
                    }
                  } else {
                    selected.remove(id);
                  }
                }),
                title: Text('${item['seriesTitle']}'),
                subtitle: Text('Episódio ${item['episodeNumber']}'),
                activeColor: const Color(0xffff6b9d),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          FilledButton.icon(
            onPressed: selected.isEmpty || running ? null : _recover,
            icon: running ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.build_circle_outlined),
            label: Text(running ? 'Recuperando...' : 'Recuperar selecionados (${selected.length})'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xffff6b9d)),
          ),
        ] else if (!loading && error == null)
          const Text('A lista ainda não foi consultada.', style: TextStyle(color: Colors.white60)),
        if (progress != null) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(progress!, style: const TextStyle(color: Colors.lightGreenAccent)),
        ),
        if (error != null) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
        ),
      ]),
    ),
  );
}

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});
  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}
class _AdminUsersScreenState extends State<AdminUsersScreen> {
  late Future<List<Map<String, dynamic>>> usersRequest = NovelAuth.users();
  late Future<List<Map<String, dynamic>>> catalogRequest = NovelAuth.catalog();
  void _reload() => setState(() { usersRequest = NovelAuth.users(); catalogRequest = NovelAuth.catalog(); });

  Future<void> _createSeries() async {
    final title = TextEditingController(), synopsis = TextEditingController(), cover = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Adicionar novelinha'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Nome da novelinha')),
        const SizedBox(height: 10),
        TextField(controller: synopsis, decoration: const InputDecoration(labelText: 'Sinopse'), maxLines: 3),
        const SizedBox(height: 10),
        TextField(controller: cover, decoration: const InputDecoration(labelText: 'URL da capa (opcional)')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar'))],
    ));
    if (ok == true && title.text.trim().isNotEmpty) {
      try {
        await NovelAuth.createSeries(title.text.trim(), synopsis.text.trim(), cover.text.trim());
        _reload();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Novelinha cadastrada.')));
      } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao cadastrar: $e'))); }
    }
    title.dispose(); synopsis.dispose(); cover.dispose();
  }

  Future<void> _deleteSeries(Map<String, dynamic> series) async {
    final title = '${series['title'] ?? 'esta novelinha'}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir publicação?'),
        content: Text('Deseja excluir "$title" e todos os episódios dela? Essa ação não pode ser desfeita.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await NovelAuth.deleteSeries('${series['id']}');
      _reload();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Publicação excluída.')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao excluir publicação: $e')),
      );
    }
  }

  Future<void> _addEpisode(Map<String, dynamic> series) async {
    final number = TextEditingController(), title = TextEditingController(), url = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Episódio • ${series['title']}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: number, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Número do episódio')),
        const SizedBox(height: 10),
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Título')),
        const SizedBox(height: 10),
        TextField(controller: url, decoration: const InputDecoration(labelText: 'Link HTTPS do vídeo')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar episódio'))],
    ));
    if (ok == true) {
      try {
        await NovelAuth.addEpisode('${series['id']}', int.parse(number.text), title.text.trim(), url.text.trim());
        _reload();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Episódio salvo.')));
      } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao salvar episódio: $e'))); }
    }
    number.dispose(); title.dispose(); url.dispose();
  }

  Widget _error(Object error) => Center(child: Padding(
    padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('Não foi possível carregar esta área: $error', textAlign: TextAlign.center),
      const SizedBox(height: 12), OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh), label: const Text('Tentar novamente')),
    ]),
  ));

  @override
  Widget build(BuildContext context) => DefaultTabController(length: 3, child: Scaffold(
    backgroundColor: const Color(0xff101018),
    appBar: AppBar(title: const Text('Painel administrativo'), actions: [
      IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh)),
    ], bottom: const TabBar(tabs: [Tab(text: 'USUÁRIOS'), Tab(text: 'CATÁLOGO'), Tab(text: 'GOOGLE DRIVE')])),
    floatingActionButton: Builder(builder: (ctx) => FloatingActionButton.extended(
      onPressed: () { if (DefaultTabController.of(ctx).index == 1) _createSeries(); else _reload(); },
      icon: const Icon(Icons.add), label: const Text('Nova novelinha'),
    )),
    body: TabBarView(children: [
      FutureBuilder<List<Map<String, dynamic>>>(future: usersRequest, builder: (context, snapshot) {
        if (snapshot.hasError) return _error(snapshot.error!);
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final users = snapshot.data!;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('Contas cadastradas: ${users.length}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          for (final item in users) Card(color: const Color(0xff1b1b27), child: ListTile(
            leading: CircleAvatar(child: Icon(item['role'] == 'admin' ? Icons.admin_panel_settings : Icons.person)),
            title: Text('${item['username'] ?? ''}'), subtitle: Text('${item['email'] ?? ''}'),
            trailing: Text(item['role'] == 'admin' ? 'ADMIN' : 'USUÁRIO', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
          )),
        ]);
      }),
      FutureBuilder<List<Map<String, dynamic>>>(future: catalogRequest, builder: (context, snapshot) {
        if (snapshot.hasError) return _error(snapshot.error!);
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final series = snapshot.data!;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('Novelinha cadastradas: ${series.length}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          for (final item in series) Card(color: const Color(0xff1b1b27), child: ListTile(
            leading: const Icon(Icons.movie_outlined), title: Text('${item['title'] ?? ''}'),
            subtitle: Text('${(item['episodes'] as List? ?? const []).length} episódios'),
            trailing: Wrap(spacing: 2, children: [
              IconButton(tooltip: 'Adicionar episódio', icon: const Icon(Icons.add_circle_outline), onPressed: () => _addEpisode(item)),
              IconButton(
                tooltip: 'Excluir publicação',
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () => _deleteSeries(item),
              ),
            ]),
          )),
          if (series.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('Nenhuma novelinha cadastrada no catálogo administrativo.')),
        ]);
      }),
      const GoogleDriveAdminScreen(),
    ]),
  ));
}
