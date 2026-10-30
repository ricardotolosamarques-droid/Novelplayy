const CACHE_NAME='novelplay-static-v1';
const STATIC=['/','/icon.svg','/manifest.json'];
self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(STATIC)));
  self.skipWaiting();
});
self.addEventListener('activate',event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(
    keys.filter(key=>key!==CACHE_NAME).map(key=>caches.delete(key))
  )));
  self.clients.claim();
});
self.addEventListener('fetch',event=>{
  const request=event.request;
  if(request.method!=='GET')return;
  const url=new URL(request.url);
  if(url.origin!==self.location.origin || url.pathname.startsWith('/api/'))return;
  if(STATIC.includes(url.pathname)){
    event.respondWith(fetch(request).then(response=>{
      if(response.ok){const copy=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put(request,copy))}
      return response;
    }).catch(()=>caches.match(request)));
  }
});