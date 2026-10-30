import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class Episode {
  final int number;
  final String title, videoUrl;
  Episode(this.number, this.title, this.videoUrl);
  factory Episode.parse(Map<String,dynamic> j) {
    final number = int.tryParse('${j['number'] ?? j['episodeNumber'] ?? j['episode_index'] ?? 1}') ?? 1;
    return Episode(number,'${j['title'] ?? j['name'] ?? 'Episódio $number'}',
      '${j['videoUrl'] ?? j['playUrl'] ?? j['video_url'] ?? j['show_collection_play_url'] ?? ''}');
  }
}
class Novel {
  final String id,title,synopsis,genre,cover;
  final List<Episode> episodes;
  final String slug;
  Novel(this.id,this.title,this.synopsis,this.genre,this.cover,this.episodes,{this.slug = ''});
  factory Novel.parse(Map<String,dynamic> j) {
    final values = j['episodes'] ?? j['episode_list'] ?? j['play_list'] ?? [];
    return Novel('${j['id'] ?? j['show_collection_id'] ?? j['playlet_id'] ?? ''}',
      '${j['title'] ?? j['name'] ?? j['playlet_name'] ?? 'Sem título'}',
      '${j['synopsis'] ?? j['description'] ?? j['intro'] ?? ''}',
      '${j['genre'] ?? j['category'] ?? ''}',
      '${j['cover'] ?? j['poster'] ?? j['cover_url'] ?? ''}',
      values is List ? values.whereType<Map>().map((x)=>Episode.parse(Map<String,dynamic>.from(x))).toList() : [],
      slug: '${j['filtered_title'] ?? ''}');
  }
}
class Catalog {
  final List<Novel> novels;
  final String origin;
  final String? warning;
  Catalog(this.novels,this.origin,[this.warning]);
}
class Sources {
  static const catalogUrl=String.fromEnvironment('CATALOG_URL');
  static const apiUrl=String.fromEnvironment('API_BASE_URL');
  // Optional community proxy, configured by the owner. Metadata only.
  // No subscription circumvention or third-party video playback.
  static const reelshortApi=String.fromEnvironment('REELSHORT_API_URL');
  static const apiIndexPath=String.fromEnvironment('API_INDEX_PATH',defaultValue:'/api/playlet/index_recommend');
  static const apiInfoPath=String.fromEnvironment('API_INFO_PATH',defaultValue:'/api/playlet/info');
  static const apiIdParam=String.fromEnvironment('API_INFO_ID_PARAM',defaultValue:'id');

  static Uri? valid(String raw) {
    final u=Uri.tryParse(raw.trim());
    return (u != null && u.scheme == 'https' && u.host.isNotEmpty && u.userInfo.isEmpty) ? u : null;
  }
  static Uri? endpoint(String path) {
    final base=valid(apiUrl);
    if(base==null || !path.startsWith('/') || path.startsWith('//')) return null;
    return base.replace(path:path,query:null,fragment:null);
  }
  static Future<dynamic> get(Uri uri) async {
    final res=await http.get(uri,headers:const {'Accept':'application/json'}).timeout(const Duration(seconds:12));
    if(res.statusCode!=200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(utf8.decode(res.bodyBytes));
  }
  static List<dynamic>? pickList(dynamic node,[int depth=0]) {
    if(depth>5) return null;
    if(node is List) return node;
    if(node is Map) {
      for(final key in ['novels','playlets','data','result','list','items','rows','records','recommend_list','video_list']) {
        if(node.containsKey(key)) {
          final list=pickList(node[key],depth+1);
          if(list!=null) return list;
        }
      }
    }
    return null;
  }
  static List<Novel> parseList(dynamic node) {
    final list=pickList(node);
    if(list==null) throw const FormatException('JSON sem lista de novelinhas');
    return list.whereType<Map>().map((x)=>Novel.parse(Map<String,dynamic>.from(x)))
      .where((n)=>n.title!='Sem título').toList();
  }
  static Future<Catalog> load() async {
    if(valid(reelshortApi)!=null) {
      try {
        final base=reelshortApi.replaceFirst(RegExp(r'/
    if(online!=null) {
      try {
        final novels=parseList(await get(online));
        if(novels.isEmpty) throw const FormatException('Catálogo vazio');
        return Catalog(novels,'Catálogo remoto');
      } catch(e) {
        return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
          'Demonstração','A API falhou: $e');
      }
    }
    return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
      'Demonstração','API não configurada. As novelinhas do Vanta Surf NÃO estão conectadas.');
  }
  static Future<Novel> details(Novel n) async {
    if(n.episodes.isNotEmpty || n.id.isEmpty) return n;
    if(valid(reelshortApi)!=null && n.slug.isNotEmpty) {
      final base=reelshortApi.replaceFirst(RegExp(r'/
    if(uri==null || !RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(apiIdParam)) return n;
    final result=await get(uri.replace(queryParameters:{apiIdParam:n.id}));
    dynamic value=result;
    for(int i=0;i<5 && value is Map;i++) {
      if(value['episodes'] is List || value['episode_list'] is List || value['play_list'] is List) {
        final parsed=Novel.parse(Map<String,dynamic>.from(value));
        return Novel(n.id,n.title,n.synopsis,n.genre,n.cover,parsed.episodes);
      }
      dynamic next;
      for(final key in ['data','result','info','playlet','detail']) {
        if(value[key] is Map) { next=value[key]; break; }
      }
      if(next==null) break;
      value=next;
    }
    throw const FormatException('API não retornou episódios reconhecíveis');
  }
}
), '');
        final u=valid('$base/recommended');
        if(u==null) throw const FormatException('Invalid ReelShort proxy URL');
        final raw=await get(u);
        if(raw is! Map || raw['books'] is! List) throw const FormatException('Invalid ReelShort catalog');
        final novels=(raw['books'] as List).whereType<Map>().map((b){
          final j=Map<String,dynamic>.from(b);
          return Novel(
            '${j['book_id'] ?? ''}', '${j['book_title'] ?? 'Sem título'}',
            '${j['special_desc'] ?? ''}', 'ReelShort', '${j['book_pic'] ?? ''}', [],
            slug:'${j['filtered_title'] ?? ''}');
        }).where((n)=>n.id.isNotEmpty && n.slug.isNotEmpty).toList();
        if(novels.isEmpty) throw const FormatException('Empty ReelShort bookshelf');
        return Catalog(novels,'ReelShort — catálogo comunitário',
          'Dados de um projeto não oficial. Reprodução de vídeos não integrada.');
      }catch(e){
        return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
          'Demonstração','Não foi possível carregar o catálogo ReelShort: $e');
      }
    }
    final online=valid(catalogUrl) ?? endpoint(apiIndexPath);
    if(online!=null) {
      try {
        final novels=parseList(await get(online));
        if(novels.isEmpty) throw const FormatException('Catálogo vazio');
        return Catalog(novels,'Catálogo remoto');
      } catch(e) {
        return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
          'Demonstração','A API falhou: $e');
      }
    }
    return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
      'Demonstração','API não configurada. As novelinhas do Vanta Surf NÃO estão conectadas.');
  }
  static Future<Novel> details(Novel n) async {
    if(n.episodes.isNotEmpty || n.id.isEmpty) return n;
    final uri=endpoint(apiInfoPath);
    if(uri==null || !RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(apiIdParam)) return n;
    final result=await get(uri.replace(queryParameters:{apiIdParam:n.id}));
    dynamic value=result;
    for(int i=0;i<5 && value is Map;i++) {
      if(value['episodes'] is List || value['episode_list'] is List || value['play_list'] is List) {
        final parsed=Novel.parse(Map<String,dynamic>.from(value));
        return Novel(n.id,n.title,n.synopsis,n.genre,n.cover,parsed.episodes);
      }
      dynamic next;
      for(final key in ['data','result','info','playlet','detail']) {
        if(value[key] is Map) { next=value[key]; break; }
      }
      if(next==null) break;
      value=next;
    }
    throw const FormatException('API não retornou episódios reconhecíveis');
  }
}
), '');
      final root=valid('$base/episodes/${Uri.encodeComponent(n.id)}');
      if(root==null) throw const FormatException('Invalid ReelShort API URL');
      final decoded=await get(root.replace(queryParameters:{'filtered_title':n.slug}));
      if(decoded is! Map || decoded['episodes'] is! List) {
        throw const FormatException('Episode list not returned by proxy');
      }
      final episodes=(decoded['episodes'] as List).whereType<Map>().map((e) {
        final number=int.tryParse('${e['episode'] ?? ''}');
        if(number==null) return null;
        return Episode(number,'Episódio $number','');
      }).whereType<Episode>().toList();
      return Novel(n.id,n.title,n.synopsis,n.genre,n.cover,episodes,slug:n.slug);
    }
    final uri=endpoint(apiInfoPath);
    if(uri==null || !RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(apiIdParam)) return n;
    final result=await get(uri.replace(queryParameters:{apiIdParam:n.id}));
    dynamic value=result;
    for(int i=0;i<5 && value is Map;i++) {
      if(value['episodes'] is List || value['episode_list'] is List || value['play_list'] is List) {
        final parsed=Novel.parse(Map<String,dynamic>.from(value));
        return Novel(n.id,n.title,n.synopsis,n.genre,n.cover,parsed.episodes);
      }
      dynamic next;
      for(final key in ['data','result','info','playlet','detail']) {
        if(value[key] is Map) { next=value[key]; break; }
      }
      if(next==null) break;
      value=next;
    }
    throw const FormatException('API não retornou episódios reconhecíveis');
  }
}
), '');
        final u=valid('$base/recommended');
        if(u==null) throw const FormatException('Invalid ReelShort proxy URL');
        final raw=await get(u);
        if(raw is! Map || raw['books'] is! List) throw const FormatException('Invalid ReelShort catalog');
        final novels=(raw['books'] as List).whereType<Map>().map((b){
          final j=Map<String,dynamic>.from(b);
          return Novel(
            '${j['book_id'] ?? ''}', '${j['book_title'] ?? 'Sem título'}',
            '${j['special_desc'] ?? ''}', 'ReelShort', '${j['book_pic'] ?? ''}', [],
            slug:'${j['filtered_title'] ?? ''}');
        }).where((n)=>n.id.isNotEmpty && n.slug.isNotEmpty).toList();
        if(novels.isEmpty) throw const FormatException('Empty ReelShort bookshelf');
        return Catalog(novels,'ReelShort — catálogo comunitário',
          'Dados de um projeto não oficial. Reprodução de vídeos não integrada.');
      }catch(e){
        return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
          'Demonstração','Não foi possível carregar o catálogo ReelShort: $e');
      }
    }
    final online=valid(catalogUrl) ?? endpoint(apiIndexPath);
    if(online!=null) {
      try {
        final novels=parseList(await get(online));
        if(novels.isEmpty) throw const FormatException('Catálogo vazio');
        return Catalog(novels,'Catálogo remoto');
      } catch(e) {
        return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
          'Demonstração','A API falhou: $e');
      }
    }
    return Catalog(parseList(jsonDecode(await rootBundle.loadString('assets/catalog.json'))),
      'Demonstração','API não configurada. As novelinhas do Vanta Surf NÃO estão conectadas.');
  }
  static Future<Novel> details(Novel n) async {
    if(n.episodes.isNotEmpty || n.id.isEmpty) return n;
    final uri=endpoint(apiInfoPath);
    if(uri==null || !RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(apiIdParam)) return n;
    final result=await get(uri.replace(queryParameters:{apiIdParam:n.id}));
    dynamic value=result;
    for(int i=0;i<5 && value is Map;i++) {
      if(value['episodes'] is List || value['episode_list'] is List || value['play_list'] is List) {
        final parsed=Novel.parse(Map<String,dynamic>.from(value));
        return Novel(n.id,n.title,n.synopsis,n.genre,n.cover,parsed.episodes);
      }
      dynamic next;
      for(final key in ['data','result','info','playlet','detail']) {
        if(value[key] is Map) { next=value[key]; break; }
      }
      if(next==null) break;
      value=next;
    }
    throw const FormatException('API não retornou episódios reconhecíveis');
  }
}
