import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class NovelSeriesUnlocks {
  static const String _baseUrl = 'https://novelplay-api-ee5f.onrender.com';

  static Future<Map<String, String>> _headers() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('novelplay_auth_token');
    if (token == null || token.isEmpty) {
      throw Exception('Entre na sua conta para desbloquear novelinhas.');
    }
    return {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  }

  static Future<Set<String>> load() async {
    final response = await http.get(Uri.parse('$_baseUrl/unlocks'), headers: await _headers())
        .timeout(const Duration(seconds: 20));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['error'] ?? 'Não foi possível carregar seus desbloqueios.');
    }
    return (data['seriesIds'] as List<dynamic>? ?? []).map((id) => '$id').toSet();
  }

  static Future<void> unlock(String seriesId) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/unlocks'),
      headers: await _headers(),
      body: jsonEncode({'seriesId': seriesId}),
    ).timeout(const Duration(seconds: 20));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['error'] ?? 'Não foi possível salvar o desbloqueio.');
    }
  }
}
