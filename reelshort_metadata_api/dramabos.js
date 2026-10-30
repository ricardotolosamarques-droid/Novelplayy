// DramaBos provider directory and optional server-side metadata proxy.
// The key is never sent to the Android client. No video URLs are exposed.
const names = [
['StarShort','starshort'],['DramaBite','dramabite'],['FreeReels','freereels'],
['FunDrama','fundrama'],['MicroDrama','microdrama'],['Vigloo','vigloo'],
['BiliTV','bilitv'],['DramaBox','dramabox'],['DramaWave','dramawave'],
['NetShort','netshort'],['iDrama','idrama'],['ShortMax','shortmax'],
['GoodShort','goodshort'],['Melolo','melolo'],['Velolo','velolo'],
['ReelShort','reelshort'],['FlickReels','flickreels'],['Stardusttv','stardusttv'],
['Serial+','serialplus'],['DotDrama','dotdrama'],['RapidTV','rapidtv'],
['ShortsWave','shortswave'],['DramaNova','dramanova'],['CubeTV','cubetv'],
['ReelBuzz','reelbuzz'],['FlareFlow','flareflow'],['MoboReels','moboreels'],
['HappyShort','happyshort'],['Reelife','reelife'],['PineDrama','pinedrama'],
['FlexTV','flextv'],['Reelala','reelala'],['Anyreel','anyreel'],
['RaptDrama','raptdrama'],['BonusTV','bonustv'],['MiniTV','minitv'],
['Gold Drama','golddrama'],['IQIYI','iqiyi'],['Bstation','bstation'],
['Joyreels','joyreels'],['KalosTV','kalostv'],['Vibeshort','vibeshort'],
];
export const providers=names.map(([name,slug])=>({
  name,slug,category:['bilitv','iqiyi','bstation'].includes(slug)?'chinese':'short'
}));
const slugs=new Set(providers.map(p=>p.slug));
const cache=new Map();
let calls=0,resetAt=Date.now()+3600000;
export const configured=()=>Boolean(process.env.DRAMABOS_API_KEY?.trim());
function send(res,status,body){
  res.writeHead(status,{'Content-Type':'application/json; charset=utf-8',
    'Cache-Control':'no-store','Access-Control-Allow-Origin':'*'});
  res.end(JSON.stringify(body));
}
const getList=data=>{
  if(Array.isArray(data))return data;
  for(const key of ['results','episodes','dramas','items','list','data','result']){
    const nested=data?.[key];
    if(Array.isArray(nested))return nested;
    if(nested&&typeof nested==='object'&&nested!==data){
      const result=getList(nested);
      if(result.length)return result;
    }
  }
  if(Array.isArray(data?.sections)){
    return data.sections.flatMap(section=>getList(section));
  }
  return [];
};
export function normalizeSearch(data){
  return getList(data).map(x=>({
    id:String(x.id??x.book_id??x.code??''),
    title:String(x.title??x.book_title??x.name??''),
    cover:String(x.cover??x.book_pic??''),
    genre:String(x.genre??''),
    synopsis:String(x.synopsis??x.description??''),
    episodes:Number(x.episodes??x.episodeCount??x.chapter_count??0),
  })).filter(x=>x.id&&x.title).slice(0,100);
}
export function normalizeEpisodes(data){
  return getList(data).map(x=>{
    const number=Number(x.number??x.episode??x.serial_number??0);
    return {
      number,title:String(x.title??x.name??'Episódio '+number),
      duration:String(x.duration??''),thumbnail:String(x.thumbnail??''),
      locked:x.locked!==false,
    };
  }).filter(x=>Number.isSafeInteger(x.number)&&x.number>0).slice(0,1000);
}
const allowedId=id=>/^[a-zA-Z0-9_:-]{1,128}$/.test(id);
function providerPath(slug,kind,query){
  const value=encodeURIComponent(query||'');
  if(kind==='home'){
    // Official DramaBos GitHub README lists provider-specific feed routes.
    if(slug==='flickreels')return '/flickreels/api/flickreels/trending?lang=en';
    if(slug==='dramabox')return '/dramabox/api/v1/discover';
    if(slug==='reelshort')return '/reelshort/api/v1/featured';
    return '/'+slug+'/api/v1/home';
  }
  if(kind==='search') {
    if(slug==='flickreels')return '/flickreels/api/flickreels/search?q='+value;
    return '/'+slug+'/api/v1/search?'+
      (slug==='shortmax'||slug==='reelshort'?'q':'keyword')+'='+value;
  }
  if(slug==='flickreels')return '/flickreels/api/flickreels/allepisode?id='+value;
  return '/'+slug+'/api/v1/episodes/'+value;
}
async function upstream(path){
  const now=Date.now(),stored=cache.get(path);
  if(stored&&stored.until>now)return stored.value;
  if(now>=resetAt){resetAt=now+3600000;calls=0;}
  if(calls>=100)throw {status:429,message:'Limite horário de proteção atingido'};
  calls++;
  let response;
  try{
    response=await fetch(new URL(path,'https://dramabos.live'),{
      redirect:'error',signal:AbortSignal.timeout(12000),
      headers:{
        Accept:'application/json',
        ...(configured() ? {Authorization:'Bearer '+process.env.DRAMABOS_API_KEY.trim()} : {}),
      },
    });
  }catch{throw {status:502,message:'Não foi possível contatar a DramaBos'};}
  if(!response.ok){
    const status=response.status;
    throw {
      status:[401,403,429].includes(status)?status:502,
      message:status===401
        ?'A DramaBos exige autenticação. Configure uma chave válida no Render.'
        :status===403
        ?'A DramaBos bloqueou o acesso (HTTP 403). Verifique as permissões da chave ou o acesso do servidor.'
        :status===404
        ?'A DramaBos respondeu HTTP 404: esta rota não está disponível no servidor, embora esteja anunciada na documentação.'
        :status===429
        ?'Limite de requisições da DramaBos atingido.'
        :'DramaBos respondeu HTTP '+status,
    };
  }
  let value;
  try{value=await response.json();}
  catch{throw {status:502,message:'Resposta JSON inválida da DramaBos'};}
  cache.set(path,{until:now+120000,value});
  if(cache.size>150)cache.clear();
  return value;
}
export async function handleDramaBos(url,req,res){
  const path=url.pathname;
  if(!path.startsWith('/api/dramabos/'))return false;
  if(path==='/api/dramabos/providers'){
    send(res,200,{providers,configured:configured(),mode:'metadata'});
    return true;
  }
  if(path==='/api/dramabos/status'){
    send(res,200,{configured:configured(),providers:providers.length,
      mode:'metadata',authentication:'optional-experiment'});
    return true;
  }
  const search=path.match(/^\/api\/dramabos\/search\/([a-z0-9]+)$/);
  const eps=path.match(/^\/api\/dramabos\/episodes\/([a-z0-9]+)\/([^/]+)$/);
  const home=path.match(/^\/api\/dramabos\/home\/([a-z0-9]+)$/);
  const slug=search?.[1]??eps?.[1]??home?.[1]??'';
  if(!slugs.has(slug)){
    send(res,404,{error:'Provedor ou rota não reconhecidos'});return true;
  }
  const id=eps?decodeURIComponent(eps[2]):null;
  const keyword=search?(url.searchParams.get('keyword')||'').trim():'';
  if(search&&(!keyword||keyword.length>100)||
     eps&&!allowedId(id)){
    send(res,400,{error:'Parâmetros inválidos'});return true;
  }
  try{
    const kind=search?'search':eps?'episodes':'home';
    const body=await upstream(providerPath(slug,kind,search?keyword:id));
    send(res,200,eps?{provider:slug,episodes:normalizeEpisodes(body)}:
      {provider:slug,results:normalizeSearch(body)});
  }catch(e){
    send(res,e.status??502,{error:e.message??'Erro na API'});
  }
  return true;
}
