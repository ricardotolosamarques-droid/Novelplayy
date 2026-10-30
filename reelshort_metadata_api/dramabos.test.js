import test from 'node:test';
import assert from 'node:assert/strict';
import {providers,normalizeSearch,normalizeEpisodes,handleDramaBos} from './dramabos.js';
test('diretório com 42 provedores distintos',()=>{
  assert.equal(providers.length,42);
  assert.equal(new Set(providers.map(x=>x.slug)).size,42);
  assert.equal(providers.filter(x=>x.category==='chinese').length,3);
});
test('metadados JSON normalizados',()=>{
  assert.equal(normalizeSearch({results:[{id:'1',title:'A'}]})[0].title,'A');
  assert.deepEqual(normalizeEpisodes({episodes:[{number:1,locked:false},
    {number:2}]}).map(x=>x.locked),[false,true]);
});
test('diretório público, busca exige chave sem revelar credencial',async()=>{
  const old=process.env.DRAMABOS_API_KEY;
  delete process.env.DRAMABOS_API_KEY;
  const mock=()=>{let status,body;return {res:{
    writeHead:(x)=>{status=x;},end:x=>{body=JSON.parse(x);}
  },get:()=>({status,body})};};
  try {
    const listing=mock();
    await handleDramaBos(new URL('http://localhost/api/dramabos/providers'),{},listing.res);
    assert.equal(listing.get().status,200);
    assert.equal(listing.get().body.providers.length,42);
    const blocked=mock();
    await handleDramaBos(new URL('http://localhost/api/dramabos/search/reelshort?keyword=love'),{},blocked.res);
    assert.equal(blocked.get().status,503);
  }finally {
    if(old!==undefined)process.env.DRAMABOS_API_KEY=old;
  }
});
