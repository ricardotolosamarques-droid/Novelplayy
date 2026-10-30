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
test('diretório e status públicos não revelam credenciais',async()=>{
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
    const status=mock();
    await handleDramaBos(new URL('http://localhost/api/dramabos/status'),{},status.res);
    assert.equal(status.get().status,200);
    assert.equal(status.get().body.configured,false);
    const invalid=mock();
    await handleDramaBos(new URL('http://localhost/api/dramabos/search/nonexistent?keyword=love'),{},invalid.res);
    assert.equal(invalid.get().status,404);
  }finally {
    if(old!==undefined)process.env.DRAMABOS_API_KEY=old;
  }
});

test('normaliza feed com seções e mantém episódios sem acesso explicitamente bloqueados',()=>{
  const feed={sections:[{title:'Trending',items:[{id:'alpha',title:'História',episodes:4}]}]};
  const titles=normalizeSearch(feed);
  assert.equal(titles.length,1);
  assert.equal(titles[0].episodes,4);
  const episodes=normalizeEpisodes({data:{episodes:[
    {number:1,locked:false},{number:2},{number:3,locked:true}
  ]}});
  assert.deepEqual(episodes.map(x=>x.locked),[false,true,true]);
});
