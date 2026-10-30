// NovelPlay metadata adapter. Inspired by the MIT-licensed project
// https://github.com/wanglinsaputra/Rest-Api-ReelShort
// Reads public metadata and provides a native-player URL only for episodes
// marked as publicly available by the official page. Never unlocks premium
// chapters, rehosts media, or bypasses login/DRM.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { URL } from 'node:url';
import { fileURLToPath } from 'node:url';

const PREFIX = '/api/v1/reelshort';
const REELSHORT_ORIGIN = 'https://www.reelshort.com';
const REGION = 'id';
const cache = new Map();
let buildId = '';
let buildLastChecked = 0;

const asArray = (value) => Array.isArray(value) ? value : [];

export function slugify(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ')
    .trim().replace(/\s+/g, '-');
}

function requireToken(value) {
  const token = String(value || '');
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(token)) {
    throw new HttpError(400, 'Identificador inválido');
  }
  return token;
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function fetchText(url) {
  const response = await fetch(url, {
    signal: AbortSignal.timeout(12000),
    headers: {
      'Accept': 'application/json, text/html;q=0.9, */*;q=0.8',
      'User-Agent': 'NovelPlay/1.1 (+public metadata and free episodes)',
    },
  });
  if (!response.ok) {
    throw new Error('Site ReelShort retornou HTTP ' + response.status);
  }
  return await response.text();
}

async function refreshBuildId() {
  const html = await fetchText(REELSHORT_ORIGIN + '/' + REGION);
  const found = html.match(/"buildId"\s*:\s*"([^"]+)"/) ||
    html.match(/\/_next\/data\/([^/]+)\/id[/.]/);
  if (!found) {
    throw new Error('O formato do site mudou: buildId não localizado');
  }
  buildId = found[1];
  buildLastChecked = Date.now();
  return buildId;
}

async function pageData(suffix) {
  const now = Date.now();
  const cached = cache.get(suffix);
  if (cached && cached.expires > now) return cached.payload;

  if (!buildId || now - buildLastChecked > 10 * 60 * 1000) {
    await refreshBuildId();
  }

  let lastError;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt === 1) await refreshBuildId();
    const path = '/_next/data/' + encodeURIComponent(buildId) +
      '/' + REGION + suffix;
    try {
      const raw = await fetchText(REELSHORT_ORIGIN + path);
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object') {
        throw new Error('Resposta não é um objeto JSON');
      }
      cache.set(suffix, { payload: parsed, expires: Date.now() + 90_000 });
      if (cache.size > 100) cache.clear();
      return parsed;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error('Falha ao obter metadados');
}

export function normalizeBook(book) {
  if (!book || typeof book !== 'object') return null;
  const title = String(book.book_title || '');
  const id = String(book.book_id || book._id || '');
  if (!title) return null;
  return {
    book_id: id,
    book_title: title,
    filtered_title: slugify(title),
    book_pic: String(book.book_pic || ''),
    special_desc: String(book.special_desc || ''),
    chapter_count: Number(book.chapter_count || 0),
  };
}

// paid_start on the public title page marks the start of paid episodes.
// Use a strict, conservative boundary (episode < paid_start) to avoid
// accidentally granting access at the transition episode.
export function publicEpisodeAccess(bookInfo, episodeNumber) {
  const number = Number(episodeNumber);
  if (!Number.isSafeInteger(number) || number < 1 || !bookInfo ||
      typeof bookInfo !== 'object') return false;
  const isPaid = Number(bookInfo.is_paid);
  const paidStart = Number(bookInfo.paid_start);
  if (isPaid === 0 && Number.isSafeInteger(paidStart) && paidStart === 0) {
    return true;
  }
  if (!Number.isSafeInteger(paidStart) || paidStart < 1) return false;
  return number < paidStart;
}

export function normalizeEpisodes(raw, bookInfo = null) {
  return asArray(raw).map((chapter) => {
    const episode = Number(chapter?.serial_number || 0);
    return {
      episode,
      chapter_id: String(chapter?.chapter_id || ''),
      free: publicEpisodeAccess(bookInfo, episode),
    };
  }).filter((episode) => Number.isSafeInteger(episode.episode) &&
    episode.episode > 0 && episode.chapter_id);
}

function matchShelf(shelves, type) {
  const words = {
    recommended: ['direkomendasikan', 'recommended'],
    newrelease: ['rilis baru', 'new release'],
    dramadub: ['drama dengan dub', 'dubbed'],
  }[type] || [];
  const found = shelves.find((shelf) => words.some(
    (word) => String(shelf?.bookshelf_name || '')
      .toLowerCase().includes(word)
  ));
  if (found) return found;
  return type === 'recommended'
    ? shelves.find((shelf) => asArray(shelf?.books).length > 0)
    : null;
}

async function bookshelf(type) {
  const payload = await pageData('.json');
  const shelves = payload?.pageProps?.fallback?.['/api/ms/hall/webInfo']
    ?.bookShelfList;
  if (!Array.isArray(shelves)) {
    throw new Error('A estrutura de estantes do ReelShort mudou');
  }
  const shelf = matchShelf(shelves, type);
  return {
    bookshelf_name: shelf?.bookshelf_name || type,
    books: asArray(shelf?.books).map(normalizeBook).filter(Boolean),
  };
}

async function search(keywords) {
  const term = String(keywords || '').trim();
  if (!term || term.length > 120) {
    throw new HttpError(400, 'Informe de 1 a 120 caracteres para pesquisar');
  }
  const suffix = '/search.json?keywords=' + encodeURIComponent(term);
  const payload = await pageData(suffix);
  return {
    results: asArray(payload?.pageProps?.books)
      .map(normalizeBook).filter(Boolean),
  };
}

async function bookEpisodes(bookId, filteredTitle) {
  const id = requireToken(bookId);
  const title = requireToken(filteredTitle);
  const slug = title + '-' + id;
  const suffix = '/movie/' + slug + '.json?slug=' +
    encodeURIComponent(slug);
  const payload = await pageData(suffix);
  const info = payload?.pageProps?.data;
  const raw = info?.online_base;
  if (!Array.isArray(raw)) {
    throw new Error('A estrutura de episódios do ReelShort mudou');
  }
  return { info, chapters: normalizeEpisodes(raw, info), id, title };
}

async function episodes(bookId, filteredTitle) {
  const { chapters } = await bookEpisodes(bookId, filteredTitle);
  return { episodes: chapters };
}

async function freeEpisodeVideo(bookId, episodeNumber, filteredTitle, chapterId) {
  const number = Number(episodeNumber);
  if (!Number.isSafeInteger(number) || number < 1 || number > 10000) {
    throw new HttpError(400, 'Número de episódio inválido');
  }
  const chapter = requireToken(chapterId);
  const { chapters, id, title } = await bookEpisodes(bookId, filteredTitle);
  const requested = chapters.find((entry) =>
    entry.episode === number && entry.chapter_id === chapter);
  if (!requested) throw new HttpError(404, 'Episódio não encontrado');
  if (!requested.free) {
    throw new HttpError(403, 'Episódio pago: reprodução independente não disponível');
  }
  // Public chapter only. No cookies, subscription tokens, credentials, or
  // requests to paid chapters. The original provider serves the HLS media.
  const slug = 'episode-' + number + '-' + title + '-' + id + '-' + chapter;
  const suffix = '/episodes/' + slug + '.json?play_time=1&slug=' +
    encodeURIComponent(slug);
  const payload = await pageData(suffix);
  const mediaInfo = payload?.pageProps?.data;
  if (!mediaInfo || mediaInfo.chapter_id !== chapter ||
      Number(mediaInfo.serial_number) !== number ||
      (Number.isSafeInteger(Number(mediaInfo.paid_start)) &&
        Number(mediaInfo.paid_start) > 0 &&
        number >= Number(mediaInfo.paid_start))) {
    throw new HttpError(403, 'Reprodução não autorizada para este episódio');
  }
  const link = String(mediaInfo.video_url || '');
  let url;
  try { url = new URL(link); } catch {
    throw new HttpError(404, 'Vídeo público indisponível');
  }
  if (url.protocol !== 'https:' || url.username || url.password ||
      !url.hostname || url.hostname === 'localhost' ||
      url.hostname.endsWith('.local')) {
    throw new HttpError(404, 'Endereço de vídeo inválido');
  }
  return { video_url: url.href, episode: number,
    duration: Number(mediaInfo.duration || 0) };
}

export function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': status === 200 ? 'public, max-age=30' : 'no-store',
  });
  res.end(body);
}

export async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,OPTIONS' });
    return res.end();
  }
  if (req.method !== 'GET') {
    return sendJson(res, 405, { error: 'Somente GET' });
  }
  try {
    const url = new URL(req.url || '/', 'http://localhost');
    const path = url.pathname;
    const publicRoutes = {
      '/': ['index.html','text/html; charset=utf-8'],
      '/index.html': ['index.html','text/html; charset=utf-8'],
      '/manifest.json': ['manifest.json','application/manifest+json; charset=utf-8'],
      '/sw.js': ['sw.js','text/javascript; charset=utf-8'],
      '/icon.svg': ['icon.svg','image/svg+xml'],
    };
    if (publicRoutes[path]) {
      const [filename, mime] = publicRoutes[path];
      const contents = await readFile(new URL('./public/' + filename, import.meta.url));
      res.writeHead(200, {
        'Content-Type': mime,
        'Cache-Control': 'no-cache, must-revalidate',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
      });
      return res.end(contents);
    }
    if (path === '/health') {
      return sendJson(res, 200,
        { status: 'ok', mode: 'public-free-hls', service: 'novelplay' });
    }
    if (path === PREFIX + '/search') {
      return sendJson(res, 200,
        await search(url.searchParams.get('keywords')));
    }
    if ([ 'recommended', 'newrelease', 'dramadub' ]
      .some((name) => path === PREFIX + '/' + name)) {
      return sendJson(res, 200,
        await bookshelf(path.slice((PREFIX + '/').length)));
    }
    const match = path.match(/^\/api\/v1\/reelshort\/episodes\/([^/]+)$/);
    if (match) {
      return sendJson(res, 200,
        await episodes(match[1], url.searchParams.get('filtered_title')));
    }
    const videoMatch = path.match(/^\/api\/v1\/reelshort\/video\/([^/]+)\/(\d+)$/);
    if (videoMatch) {
      return sendJson(res, 200, await freeEpisodeVideo(
        videoMatch[1], videoMatch[2],
        url.searchParams.get('filtered_title'),
        url.searchParams.get('chapter_id'),
      ));
    }
    return sendJson(res, 404, { error: 'Rota não encontrada' });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 502;
    return sendJson(res, status, {
      error: error instanceof Error ? error.message : 'Erro desconhecido',
    });
  }
}

if (process.argv[1] &&
    fileURLToPath(import.meta.url) === fileURLToPath(
      new URL('file://' + process.argv[1]).href
    )) {
  const port = Number(process.env.PORT || 3000);
  http.createServer((req, res) => {
    handler(req, res).catch((error) =>
      sendJson(res, 500, { error: String(error) }));
  }).listen(port, '0.0.0.0', () => {
    console.log('NovelPlay metadata server on port ' + port);
  });
}
