// NovelPlay metadata adapter. Inspired by the MIT-licensed project
// https://github.com/wanglinsaputra/Rest-Api-ReelShort
// This implementation reads publicly exposed catalog metadata only.
// It does not expose episode video URLs or circumvent paid access.
import http from 'node:http';
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
      'User-Agent': 'NovelPlay-Metadata/1.0 (+public catalog only)',
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

export function normalizeEpisodes(raw) {
  return asArray(raw).map((episode) => ({
    episode: Number(episode?.serial_number || 0),
    chapter_id: String(episode?.chapter_id || ''),
  })).filter((episode) => Number.isInteger(episode.episode) &&
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

async function episodes(bookId, filteredTitle) {
  const id = requireToken(bookId);
  const title = requireToken(filteredTitle);
  const slug = title + '-' + id;
  const suffix = '/movie/' + slug + '.json?slug=' +
    encodeURIComponent(slug);
  const payload = await pageData(suffix);
  const raw = payload?.pageProps?.data?.online_base;
  if (!Array.isArray(raw)) {
    throw new Error('A estrutura de episódios do ReelShort mudou');
  }
  return { episodes: normalizeEpisodes(raw) };
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
    if (path === '/health') {
      return sendJson(res, 200,
        { status: 'ok', mode: 'metadata-only', service: 'novelplay' });
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
