import test from 'node:test';
import assert from 'node:assert/strict';
import { slugify, normalizeBook, normalizeEpisodes, publicEpisodeAccess, handler } from './server.js';

test('normaliza título para slug', () => {
  assert.equal(slugify('A Grande História!'), 'a-grande-hist-ria');
});
test('normaliza títulos e IDs de episódio', () => {
  assert.deepEqual(normalizeBook({book_id:'123',book_title:'A drama',book_pic:'pic'}).book_id,'123');
  assert.deepEqual(normalizeEpisodes([{serial_number:1,chapter_id:'x'},{serial_number:0,chapter_id:''}]),
    [{episode:1,chapter_id:'x',free:false}]);
});
test('responde rota de saúde sem acessar serviços externos',async()=>{
  const request={method:'GET',url:'/health'};
  let status;
  let output;
  const response={writeHead:(code)=>{status=code},end:(text)=>{output=JSON.parse(text)}};
  await handler(request,response);
  assert.equal(status,200);
  assert.equal(output.mode,'public-free-hls');
});
test('não libera episódios pagos ou sem metadados públicos',()=>{
  const book={is_paid:1,paid_start:10};
  assert.equal(publicEpisodeAccess(book,1),true);
  assert.equal(publicEpisodeAccess(book,9),true);
  assert.equal(publicEpisodeAccess(book,10),false);
  assert.equal(publicEpisodeAccess(book,11),false);
  assert.equal(publicEpisodeAccess({},1),false);
  assert.equal(publicEpisodeAccess({is_paid:0,paid_start:0},12),true);
  const episodes=normalizeEpisodes(
    [{serial_number:9,chapter_id:'free'},
      {serial_number:10,chapter_id:'paid'}],book);
  assert.deepEqual(episodes.map(e=>e.free),[true,false]);
});
test('rejeita rota de vídeo com identificadores inválidos sem acessar a fonte',async()=>{
  const request={method:'GET',url:'/api/v1/reelshort/video/123/0?filtered_title=sample&chapter_id=chapter'};
  let status=0;let output='';
  const response={writeHead:(code)=>{status=code},end:(data)=>{output=String(data)}};
  await handler(request,response);
  assert.equal(status,400);
  assert.ok(output.includes('Número de episódio inválido'));
});

test('entrega página web e manifesto sem criar sessão de instalação',async()=>{
  for(const [path,mime] of [['/','text/html'],['/manifest.json','application/manifest+json'],['/icon.svg','image/svg+xml']]){
    let status=0;let contentType='';let body;
    const response={writeHead:(code,headers)=>{status=code;contentType=headers['Content-Type'];},end:(data)=>{body=String(data);}};
    await handler({method:'GET',url:path},response);
    assert.equal(status,200);
    assert.ok(contentType.startsWith(mime));
    assert.ok(body.length>100);
  }
});
