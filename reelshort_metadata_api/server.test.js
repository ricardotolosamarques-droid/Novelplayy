import test from 'node:test';
import assert from 'node:assert/strict';
import { slugify, normalizeBook, normalizeEpisodes, handler } from './server.js';

test('normaliza título para slug', () => {
  assert.equal(slugify('A Grande História!'), 'a-grande-hist-ria');
});
test('normaliza títulos e IDs de episódio', () => {
  assert.deepEqual(normalizeBook({book_id:'123',book_title:'A drama',book_pic:'pic'}).book_id,'123');
  assert.deepEqual(normalizeEpisodes([{serial_number:1,chapter_id:'x'},{serial_number:0,chapter_id:''}]),
    [{episode:1,chapter_id:'x'}]);
});
test('responde rota de saúde sem acessar serviços externos',async()=>{
  const request={method:'GET',url:'/health'};
  let status;
  let output;
  const response={writeHead:(code)=>{status=code},end:(text)=>{output=JSON.parse(text)}};
  await handler(request,response);
  assert.equal(status,200);
  assert.equal(output.mode,'metadata-only');
});
test('não disponibiliza rota de vídeo',async()=>{
  const request={method:'GET',url:'/api/v1/reelshort/video/123/1'};
  let status;
  const response={writeHead:(code)=>{status=code},end:()=>{}};
  await handler(request,response);
  assert.equal(status,404);
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
