import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'catalog.dart';
void main()=>runApp(const NovelPlay());
class NovelPlay extends StatelessWidget {
 const NovelPlay({super.key});
 @override Widget build(BuildContext context)=>MaterialApp(
  title:'NovelPlay',debugShowCheckedModeBanner:false,
  theme:ThemeData(useMaterial3:true,brightness:Brightness.dark,colorSchemeSeed:const Color(0xffdc467b)),
  home:const Home());
}
class Home extends StatefulWidget {const Home({super.key}); @override State<Home> createState()=>_HomeState();}
class _HomeState extends State<Home>{
 late Future<Catalog> catalog=Sources.load();
 String search='';
 @override Widget build(BuildContext context)=>Scaffold(
  appBar:AppBar(title:const Text('NovelPlay'),actions:[IconButton(onPressed:()=>setState(()=>catalog=Sources.load()),icon:const Icon(Icons.refresh))]),
  body:FutureBuilder<Catalog>(future:catalog,builder:(context,s){
   if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
   if(!s.hasData)return const Center(child:CircularProgressIndicator());
   final c=s.data!;
   final items=c.novels.where((n)=>n.title.toLowerCase().contains(search.toLowerCase())).toList();
   return ListView(padding:const EdgeInsets.all(16),children:[
    Text('Novelinhas',style:Theme.of(context).textTheme.headlineMedium),
    Text(c.origin,style:const TextStyle(color:Colors.white70)),
    if(c.warning!=null) Padding(padding:const EdgeInsets.symmetric(vertical:10),child:Text(c.warning!,style:const TextStyle(color:Colors.amber))),
    TextField(decoration:const InputDecoration(labelText:'Buscar novelinhas',prefixIcon:Icon(Icons.search)),onChanged:(x)=>setState(()=>search=x)),
    const SizedBox(height:12),
    for(final n in items) Card(child:ListTile(
      leading:Cover(n.cover),
      title:Text(n.title),subtitle:Text(n.genre.isEmpty?'Ver episódios':n.genre),
      trailing:const Icon(Icons.chevron_right),
      onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>Details(n))))),
    if(items.isEmpty)const Padding(padding:EdgeInsets.all(24),child:Text('Nenhuma novelinha encontrada.')),
   ]);
  }));
}
class Cover extends StatelessWidget {
 final String url;const Cover(this.url,{super.key});
 @override Widget build(BuildContext context)=>SizedBox(width:64,height:84,child:Sources.valid(url)!=null?
  Image.network(url,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.movie)):
  const Icon(Icons.movie));
}
class Details extends StatefulWidget {final Novel novel;const Details(this.novel,{super.key});@override State<Details> createState()=>_DetailsState();}
class _DetailsState extends State<Details> {
 late Future<Novel> request=Sources.details(widget.novel);
 @override Widget build(BuildContext context)=>Scaffold(
  appBar:AppBar(title:Text(widget.novel.title)),
  body:FutureBuilder<Novel>(future:request,builder:(ctx,s){
   if(s.hasError)return Center(child:Padding(padding:const EdgeInsets.all(20),child:Text('Falha na lista de episódios: ${s.error}')));
   if(!s.hasData)return const Center(child:CircularProgressIndicator());
   final n=s.data!;
   return ListView(padding:const EdgeInsets.all(16),children:[
    Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Cover(n.cover),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(n.title,style:Theme.of(context).textTheme.titleLarge),Text(n.synopsis)]))]),
    const SizedBox(height:24),const Text('Episódios',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold)),
    if(n.episodes.isEmpty)const Padding(padding:EdgeInsets.all(16),child:Text('Não há episódios liberados nesta fonte.')),
    for(final e in n.episodes)ListTile(
     leading:CircleAvatar(child:Text('${e.number}')),
     title:Text(e.title),trailing:const Icon(Icons.play_arrow),
     onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>Player(e)))),
   ]);
  }));
}
class Player extends StatefulWidget {final Episode e;const Player(this.e,{super.key});@override State<Player> createState()=>_PlayerState();}
class _PlayerState extends State<Player> {
 VideoPlayerController? player; String? error;bool loading=true;
 @override void initState(){super.initState();init();}
 Future<void> init()async{
  final u=Sources.valid(widget.e.videoUrl);
  if(u==null){if(mounted)setState((){error='Link de vídeo ausente ou inválido.';loading=false;});return;}
  final p=VideoPlayerController.networkUrl(u);player=p;
  try{await p.initialize();if(!mounted)return;setState(()=>loading=false);await p.play();}
  catch(e){if(mounted)setState((){error='Não foi possível abrir o vídeo: $e';loading=false;});}
 }
 @override void dispose(){player?.dispose();super.dispose();}
 @override Widget build(BuildContext context)=>Scaffold(
  appBar:AppBar(title:Text(widget.e.title)),
  body:Center(child:loading?const CircularProgressIndicator():error!=null?
   Padding(padding:const EdgeInsets.all(20),child:Text(error!,textAlign:TextAlign.center)):
   Column(mainAxisAlignment:MainAxisAlignment.center,children:[
    if(player!=null)AspectRatio(aspectRatio:player!.value.aspectRatio>0?player!.value.aspectRatio:9/16,child:VideoPlayer(player!)),
    const SizedBox(height:16),
    IconButton.filled(onPressed:()=>setState((){if(player!.value.isPlaying){player!.pause();}else{player!.play();}}),
      icon:Icon(player!.value.isPlaying?Icons.pause:Icons.play_arrow)),
   ])));
}
