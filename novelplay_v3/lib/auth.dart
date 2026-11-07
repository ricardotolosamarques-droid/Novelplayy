import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'drive_screen.dart';
import 'reelshort_web.dart';

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

class NovelAuth {
  static const _tokenKey = 'novelplay_auth_token';
  static Future<String?> token() async => (await SharedPreferences.getInstance()).getString(_tokenKey);
  static Future<void> saveToken(String value) async => (await SharedPreferences.getInstance()).setString(_tokenKey, value);
  static Future<void> logout() async => (await SharedPreferences.getInstance()).remove(_tokenKey);

  static Future<Map<String, dynamic>> _request(String path, {Map<String, dynamic>? body, String? bearer}) async {
    final response = await (body == null
      ? http.get(Uri.parse('$_authBaseUrl$path'), headers: bearer == null ? {} : {'Authorization': 'Bearer $bearer'})
      : http.post(Uri.parse('$_authBaseUrl$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)))
      .timeout(const Duration(seconds: 25));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(data['error'] ?? 'Não foi possível concluir a solicitação.');
    return data;
  }

  static Future<NovelUser?> restore() async {
    final saved = await token();
    if (saved == null) return null;
    try {
      final data = await _request('/auth/me', bearer: saved);
      return NovelUser.fromJson(data['user'] as Map<String, dynamic>);
    } catch (_) {
      // Falhas temporárias de rede/servidor não devem apagar a credencial.
      // Uma resposta de autenticação inválida será tratada quando a API voltar.
      return null;
    }
  }

  static Future<NovelUser> login(String identity, String password) async {
    final data = await _request('/auth/login', body: {'identity': identity, 'password': password});
    await saveToken(data['token'] as String);
    return NovelUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  static Future<NovelUser> register(String username, String email, String password) async {
    final data = await _request('/auth/register', body: {'username': username, 'email': email, 'password': password});
    await saveToken(data['token'] as String);
    return NovelUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  static Future<List<Map<String, dynamic>>> users() async {
    final saved = await token();
    if (saved == null) throw Exception('Faça login novamente.');
    final data = await _request('/admin/users', bearer: saved);
    return (data['users'] as List).cast<Map<String, dynamic>>();
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}
class _AuthGateState extends State<AuthGate> {
  NovelUser? user;
  bool loading = true;
  @override
  void initState() { super.initState(); _restore(); }
  Future<void> _restore() async {
    final restored = await NovelAuth.restore();
    if (!mounted) return;
    setState(() { user = restored; loading = false; });
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (value) { if (value == 'logout') _signOut(); },
            itemBuilder: (_) => [PopupMenuItem(enabled: false, child: Text(user!.username)), const PopupMenuItem(value: 'logout', child: Text('Sair da conta'))],
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

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});
  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}
class _AdminUsersScreenState extends State<AdminUsersScreen> {
  late Future<List<Map<String, dynamic>>> request = NovelAuth.users();
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff101018),
    appBar: AppBar(
      title: const Text('Painel administrativo'),
      actions: [
        IconButton(
          tooltip: 'Abrir ReelShort',
          icon: const Icon(Icons.public),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReelShortPage(
                url: ReelShortPage.homeUrl,
                title: 'ReelShort',
              ),
            ),
          ),
        ),
      ],
    ),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: request,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Erro: ${snapshot.error}')));
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
      },
    ),
  );
}
