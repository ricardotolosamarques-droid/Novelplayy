const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { Pool } = require('pg');
const rateLimit = require('express-rate-limit');

const app = express();
app.set('trust proxy', 1);
app.use(helmet());
app.use(cors({ origin: true }));
app.use(express.json({ limit: '20kb' }));
app.use('/auth', rateLimit({ windowMs: 15 * 60 * 1000, limit: 30, standardHeaders: true, legacyHeaders: false }));

const required = ['DATABASE_URL', 'JWT_SECRET', 'ADMIN_PASSWORD'];
for (const key of required) {
  if (!process.env[key]) {
    console.error(`Variável obrigatória ausente: ${key}`);
    process.exit(1);
  }
}
if (process.env.ADMIN_PASSWORD.length < 12 || process.env.JWT_SECRET.length < 32) {
  console.error('ADMIN_PASSWORD precisa ter ao menos 12 caracteres e JWT_SECRET ao menos 32.');
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_SSL === 'false' ? false : { rejectUnauthorized: false }
});

async function initializeDatabase() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS app_users (
      id BIGSERIAL PRIMARY KEY,
      username VARCHAR(32) NOT NULL UNIQUE,
      email VARCHAR(254) NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      role VARCHAR(16) NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS series_unlocks (
      id BIGSERIAL PRIMARY KEY,
      user_id BIGINT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
      series_id VARCHAR(255) NOT NULL,
      unlocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (user_id, series_id)
    )
  `);


  await pool.query(`
    CREATE TABLE IF NOT EXISTS catalog_series (
      id BIGSERIAL PRIMARY KEY,
      title VARCHAR(180) NOT NULL UNIQUE,
      synopsis TEXT NOT NULL DEFAULT '',
      cover_url TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS catalog_episodes (
      id BIGSERIAL PRIMARY KEY,
      series_id BIGINT NOT NULL REFERENCES catalog_series(id) ON DELETE CASCADE,
      episode_number INTEGER NOT NULL CHECK (episode_number > 0),
      title VARCHAR(180) NOT NULL,
      video_url TEXT NOT NULL DEFAULT '',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (series_id, episode_number)
    )
  `);

  // Imported metadata can exist before an authorized playback URL is supplied.
  await pool.query("ALTER TABLE catalog_episodes ALTER COLUMN video_url SET DEFAULT ''");
  await pool.query('ALTER TABLE catalog_episodes ALTER COLUMN video_url DROP NOT NULL');
  await pool.query('ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS source_episode_id TEXT NOT NULL DEFAULT \'\'');
  await pool.query('ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS source_is_free BOOLEAN');

  const adminUsername = (process.env.ADMIN_USERNAME || 'Admin').trim();
  const adminEmail = (process.env.ADMIN_EMAIL || 'admin@novelplay.local').trim().toLowerCase();
  const adminHash = await bcrypt.hash(process.env.ADMIN_PASSWORD, 12);
  await pool.query(
    `INSERT INTO app_users (username, email, password_hash, role)
     VALUES ($1, $2, $3, 'admin')
     ON CONFLICT (username) DO UPDATE
       SET email = EXCLUDED.email, password_hash = EXCLUDED.password_hash, role = 'admin'`,
    [adminUsername, adminEmail, adminHash]
  );
}

function makeToken(user) {
  return jwt.sign(
    { sub: String(user.id), role: user.role, username: user.username },
    process.env.JWT_SECRET,
    { expiresIn: '7d', issuer: 'novelplay-api', audience: 'novelplay-app' }
  );
}

function publicUser(user) {
  return { id: String(user.id), username: user.username, email: user.email, role: user.role };
}

function authRequired(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  try {
    req.auth = jwt.verify(token, process.env.JWT_SECRET, {
      issuer: 'novelplay-api',
      audience: 'novelplay-app'
    });
    next();
  } catch (_) {
    return res.status(401).json({ error: 'Sessão inválida ou expirada.' });
  }
}

app.get('/health', (_req, res) => res.json({ ok: true, service: 'novelplay-api' }));

app.post('/auth/register', async (req, res) => {
  const username = String(req.body.username || '').trim();
  const email = String(req.body.email || '').trim().toLowerCase();
  const password = String(req.body.password || '');
  if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) {
    return res.status(400).json({ error: 'Usuário deve ter 3 a 32 caracteres (letras, números, ponto, traço ou _).' });
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    return res.status(400).json({ error: 'Informe um e-mail válido.' });
  }
  if (password.length < 8 || password.length > 72) {
    return res.status(400).json({ error: 'A senha deve ter entre 8 e 72 caracteres.' });
  }
  if (username.toLowerCase() === (process.env.ADMIN_USERNAME || 'Admin').toLowerCase()) {
    return res.status(409).json({ error: 'Este nome de usuário não está disponível.' });
  }
  try {
    const hash = await bcrypt.hash(password, 12);
    const result = await pool.query(
      `INSERT INTO app_users (username, email, password_hash, role)
       VALUES ($1, $2, $3, 'user')
       RETURNING id, username, email, role`,
      [username, email, hash]
    );
    const user = result.rows[0];
    return res.status(201).json({ token: makeToken(user), user: publicUser(user) });
  } catch (error) {
    if (error.code === '23505') return res.status(409).json({ error: 'Usuário ou e-mail já cadastrado.' });
    console.error('Erro no cadastro:', error.message);
    return res.status(500).json({ error: 'Não foi possível criar a conta.' });
  }
});

app.post('/auth/login', async (req, res) => {
  const identity = String(req.body.identity || '').trim();
  const password = String(req.body.password || '');
  if (!identity || !password) return res.status(400).json({ error: 'Informe usuário/e-mail e senha.' });
  try {
    const result = await pool.query(
      `SELECT id, username, email, password_hash, role
       FROM app_users WHERE LOWER(username) = LOWER($1) OR LOWER(email) = LOWER($1)
       LIMIT 1`,
      [identity]
    );
    const user = result.rows[0];
    const valid = user && await bcrypt.compare(password, user.password_hash);
    if (!valid) return res.status(401).json({ error: 'Usuário ou senha incorretos.' });
    return res.json({ token: makeToken(user), user: publicUser(user) });
  } catch (error) {
    console.error('Erro no login:', error.message);
    return res.status(500).json({ error: 'Não foi possível entrar.' });
  }
});

app.get('/auth/me', authRequired, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, username, email, role FROM app_users WHERE id = $1',
      [req.auth.sub]
    );
    if (!result.rowCount) return res.status(404).json({ error: 'Conta não encontrada.' });
    return res.json({ user: publicUser(result.rows[0]) });
  } catch (error) {
    console.error('Erro ao consultar conta:', error.message);
    return res.status(500).json({ error: 'Não foi possível consultar a conta.' });
  }
});

app.get('/unlocks', authRequired, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT series_id FROM series_unlocks WHERE user_id = $1 ORDER BY unlocked_at DESC',
      [req.auth.sub]
    );
    return res.json({ seriesIds: result.rows.map(row => row.series_id) });
  } catch (error) {
    console.error('Erro ao consultar novelinhas desbloqueadas:', error.message);
    return res.status(500).json({ error: 'Não foi possível consultar seus desbloqueios.' });
  }
});

app.post('/unlocks', authRequired, async (req, res) => {
  const seriesId = String(req.body.seriesId || '').trim();
  if (!seriesId || seriesId.length > 255) {
    return res.status(400).json({ error: 'Identificador da novelinha inválido.' });
  }
  try {
    const result = await pool.query(
      `INSERT INTO series_unlocks (user_id, series_id)
       VALUES ($1, $2)
       ON CONFLICT (user_id, series_id) DO NOTHING
       RETURNING series_id`,
      [req.auth.sub, seriesId]
    );
    return res.status(200).json({ unlocked: true, alreadyUnlocked: result.rowCount === 0, seriesId });
  } catch (error) {
    console.error('Erro ao salvar desbloqueio:', error.message);
    return res.status(500).json({ error: 'Não foi possível salvar o desbloqueio.' });
  }
});


function isHttpsUrl(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === 'https:' && Boolean(parsed.hostname) && !parsed.username && !parsed.password;
  } catch (_) {
    return false;
  }
}


/*
 * Integração de metadados ReelShort baseada no contrato público do projeto:
 * https://github.com/wanglinsaputra/Rest-Api-ReelShort (MIT).
 * Pesquisa, metadados e consulta de URLs de reprodução quando o administrador confirma
 * que possui autorização para reproduzir e distribuir o conteúdo importado.
 */
const reelShortLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 60, standardHeaders: true, legacyHeaders: false });
let reelShortBuildId = null;
let reelShortBuildIdFetchedAt = 0;

const reelShortHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'pt-BR,pt;q=0.9,en;q=0.8',
  'Referer': 'https://www.reelshort.com/',
  'Origin': 'https://www.reelshort.com'
};

async function getReelShortBuildId(force = false) {
  if (!force && reelShortBuildId && Date.now() - reelShortBuildIdFetchedAt < 30 * 60 * 1000) {
    return reelShortBuildId;
  }
  const response = await fetch('https://www.reelshort.com/pt', {
    headers: reelShortHeaders,
    signal: AbortSignal.timeout(12000)
  });
  if (!response.ok) throw new Error('Não foi possível consultar o catálogo do ReelShort.');
  const html = await response.text();
  const match = html.match(/"buildId":"([^"]+)"/) || html.match(/\/id\/_next\/data\/([^/]+)\//);
  if (!match) throw new Error('O ReelShort alterou a página de catálogo; tente novamente mais tarde.');
  reelShortBuildId = match[1];
  reelShortBuildIdFetchedAt = Date.now();
  return reelShortBuildId;
}

function normalizeReelShortSlug(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-+/g, '-')
    .slice(0, 180);
}

async function reelShortJson(path, retry = true) {
  const buildId = await getReelShortBuildId();
  const url = 'https://www.reelshort.com/_next/data/' + encodeURIComponent(buildId) + '/pt' + path;
  const response = await fetch(url, {
    headers: reelShortHeaders,
    signal: AbortSignal.timeout(15000)
  });
  const body = await response.text();
  if (response.status === 404 && retry) {
    await getReelShortBuildId(true);
    return reelShortJson(path, false);
  }
  if (!response.ok) throw new Error('O ReelShort respondeu HTTP ' + response.status + '.');
  try {
    return JSON.parse(body);
  } catch (_) {
    if (retry) {
      await getReelShortBuildId(true);
      return reelShortJson(path, false);
    }
    throw new Error('Resposta inesperada do catálogo ReelShort.');
  }
}

async function getReelShortVideoUrl(episodeNumber, filteredTitle, bookId, chapterId) {
  const slug = 'episode-' + episodeNumber + '-' + filteredTitle + '-' + bookId + '-' + chapterId;
  const query = new URLSearchParams({ play_time: '1', slug }).toString();
  const data = await reelShortJson('/episodes/' + encodeURIComponent(slug) + '.json?' + query);
  const episode = data && data.pageProps && data.pageProps.data ? data.pageProps.data : {};
  const videoUrl = String(episode.video_url || '');
  return isHttpsUrl(videoUrl) ? videoUrl : '';
}

app.get('/reelshort/search', reelShortLimiter, async (req, res) => {
  const keywords = String(req.query.keywords || '').trim().slice(0, 120);
  if (!keywords) return res.status(400).json({ error: 'Informe o nome da novelinha.' });
  try {
    const query = new URLSearchParams({ keywords }).toString();
    const data = await reelShortJson('/search.json?' + query);
    const books = data && data.pageProps && Array.isArray(data.pageProps.books) ? data.pageProps.books : [];
    const results = books.map(book => ({
      book_id: String(book._id || book.book_id || ''),
      book_title: String(book.book_title || ''),
      filtered_title: normalizeReelShortSlug(book.filtered_title || book.book_title),
      book_pic: String(book.book_pic || ''),
      special_desc: String(book.special_desc || ''),
      chapter_count: Number(book.chapter_count || 0)
    })).filter(book => book.book_id && book.book_title);
    return res.json({ results });
  } catch (error) {
    console.error('Erro na pesquisa ReelShort:', error.message);
    return res.status(502).json({ error: error.message || 'Não foi possível pesquisar no ReelShort.' });
  }
});

function findReelShortBookDetails(value, depth = 0) {
  if (!value || typeof value !== 'object' || depth > 6) return null;
  if (!Array.isArray(value)) {
    for (const key of ['online_base', 'onlineBase', 'chapter_list', 'chapters']) {
      if (Array.isArray(value[key])) return { details: value, episodes: value[key] };
    }
    for (const child of Object.values(value)) {
      const found = findReelShortBookDetails(child, depth + 1);
      if (found) return found;
    }
  }
  return null;
}

async function getReelShortBookDetails(slug) {
  // O ReelShort passou a entregar os dados SSR em __NEXT_DATA__;
  // a antiga rota _next/data deixou de devolver a lista nesta página.
  const encodedSlug = encodeURIComponent(slug);
  const routes = ['/pt/movie/', '/pt/full-episodes/'];
  const errors = [];
  for (const route of routes) {
    try {
      const url = 'https://www.reelshort.com' + route + encodedSlug;
      const response = await fetch(url, {
        headers: {
          ...reelShortHeaders,
          Accept: 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'Accept-Language': 'pt-BR,pt;q=0.9,en;q=0.8'
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(20000)
      });
      const html = await response.text();
      if (!response.ok) {
        errors.push(route + ': HTTP ' + response.status);
        continue;
      }
      const match = html.match(/<script[^>]+id=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/i);
      if (!match) {
        errors.push(route + ': __NEXT_DATA__ não encontrado');
        continue;
      }
      let payload;
      try {
        payload = JSON.parse(match[1]);
      } catch (_) {
        errors.push(route + ': JSON SSR inválido');
        continue;
      }
      const pageProps = payload && payload.props && payload.props.pageProps
        ? payload.props.pageProps
        : (payload && payload.pageProps ? payload.pageProps : {});
      const found = findReelShortBookDetails(pageProps);
      if (found && found.episodes.length) {
        const details = found.details;
        const unique = new Map();
        for (const item of found.episodes) {
          const id = String(item.chapter_id || item.chapterId || item._id || '');
          if (id) unique.set(id, item);
        }
        return { details, episodes: Array.from(unique.values()) };
      }
      errors.push(route + ': página carregou, mas sem lista de episódios');
    } catch (error) {
      errors.push(route + ': ' + error.message);
    }
  }
  throw new Error('Não foi possível localizar os episódios na página pública do ReelShort. ' + errors.join(' | '));
}

app.get('/reelshort/episodes/:bookId', reelShortLimiter, async (req, res) => {
  const bookId = String(req.params.bookId || '');
  const filteredTitle = normalizeReelShortSlug(req.query.filtered_title);
  if (!/^[A-Za-z0-9_-]{4,100}$/.test(bookId) || !filteredTitle) {
    return res.status(400).json({ error: 'Identificador ou título de origem inválido.' });
  }
  try {
    const slug = filteredTitle + '-' + bookId;
    const found = await getReelShortBookDetails(slug);
    const details = found.details;
    const sourceEpisodes = found.episodes;
    const paidStart = Number(details.paid_start);
    const isPaid = Number(details.is_paid);
    const episodes = sourceEpisodes.map(item => {
      const number = Number(item.serial_number || item.episode || item.episode_number || 0);
      const chapterId = String(item.chapter_id || item.chapterId || item._id || '');
      const free = isPaid === 0 && Number.isSafeInteger(paidStart) && paidStart === 0
        ? true
        : Number.isSafeInteger(paidStart) && paidStart > 0 && number < paidStart;
      return { episode: number, chapter_id: chapterId, free };
    }).filter(item => Number.isSafeInteger(item.episode) && item.episode > 0 && item.chapter_id);
    if (!episodes.length) {
      throw new Error('A página foi encontrada, mas não trouxe números e identificadores de episódios reconhecíveis.');
    }
    return res.json({
      book: {
        book_title: String(details.book_title || details.title || ''),
        special_desc: String(details.special_desc || details.description || ''),
        book_pic: String(details.book_pic || details.cover || '')
      },
      episodes
    });
  } catch (error) {
    console.error('Erro ao consultar episódios ReelShort:', error.message);
    return res.status(502).json({ error: error.message || 'Não foi possível obter os episódios.' });
  }
});

// Catálogo público: somente séries e episódios publicados pelo administrador.
app.get('/catalog', async (_req, res) => {
  try {
    const seriesResult = await pool.query(
      'SELECT id, title, synopsis, cover_url, created_at FROM catalog_series ORDER BY created_at DESC, id DESC'
    );
    const episodeResult = await pool.query(
      'SELECT id, series_id, episode_number, title, video_url, source_episode_id, source_is_free FROM catalog_episodes ORDER BY episode_number ASC'
    );
    const bySeries = new Map();
    for (const row of seriesResult.rows) {
      bySeries.set(String(row.id), {
        id: String(row.id),
        title: row.title,
        synopsis: row.synopsis,
        coverUrl: row.cover_url,
        episodes: []
      });
    }
    for (const row of episodeResult.rows) {
      const series = bySeries.get(String(row.series_id));
      if (series) series.episodes.push({
        id: String(row.id),
        number: row.episode_number,
        title: row.title,
        videoUrl: row.video_url,
        sourceEpisodeId: row.source_episode_id,
        sourceIsFree: row.source_is_free
      });
    }
    return res.json({ series: Array.from(bySeries.values()) });
  } catch (error) {
    console.error('Erro ao carregar catálogo autorizado:', error.message);
    return res.status(500).json({ error: 'Não foi possível carregar o catálogo.' });
  }
});

app.post('/admin/catalog/series', authRequired, async (req, res) => {
  if (req.auth.role !== 'admin') return res.status(403).json({ error: 'Acesso exclusivo do administrador.' });
  const title = String(req.body.title || '').trim();
  const synopsis = String(req.body.synopsis || '').trim();
  const coverUrl = String(req.body.coverUrl || '').trim();
  if (!title || title.length > 180) return res.status(400).json({ error: 'O nome da série é obrigatório e deve ter até 180 caracteres.' });
  if (synopsis.length > 4000) return res.status(400).json({ error: 'A descrição é muito longa.' });
  if (coverUrl && (!isHttpsUrl(coverUrl) || coverUrl.length > 2000)) return res.status(400).json({ error: 'O link da capa precisa ser HTTPS válido.' });
  try {
    const result = await pool.query(
      'INSERT INTO catalog_series (title, synopsis, cover_url) VALUES ($1, $2, $3) RETURNING id, title',
      [title, synopsis, coverUrl]
    );
    return res.status(201).json({ series: { id: String(result.rows[0].id), title: result.rows[0].title } });
  } catch (error) {
    if (error.code === '23505') return res.status(409).json({ error: 'Já existe uma série com esse nome.' });
    console.error('Erro ao criar série:', error.message);
    return res.status(500).json({ error: 'Não foi possível criar a série.' });
  }
});

app.post('/admin/catalog/import', authRequired, async (req, res) => {
  if (req.auth.role !== 'admin') return res.status(403).json({ error: 'Acesso exclusivo do administrador.' });
  const title = String(req.body.title || '').trim();
  const synopsis = String(req.body.synopsis || '').trim();
  const coverUrl = String(req.body.coverUrl || '').trim();
  const episodes = Array.isArray(req.body.episodes) ? req.body.episodes : [];
  const authorizedPlayback = req.body.authorizedPlayback === true;
  const sourceBookId = String(req.body.sourceBookId || '').trim();
  const sourceFilteredTitle = String(req.body.sourceFilteredTitle || '').trim();
  if (!authorizedPlayback) return res.status(400).json({ error: 'Confirme que possui autorização para reproduzir e distribuir os vídeos importados.' });
  if (!/^[A-Za-z0-9_-]{4,100}$/.test(sourceBookId) || !/^[\p{L}\p{N}-]{1,180}$/u.test(sourceFilteredTitle)) return res.status(400).json({ error: 'Dados de origem ReelShort inválidos.' });
  if (!title || title.length > 180) return res.status(400).json({ error: 'Nome da série inválido.' });
  if (synopsis.length > 4000) return res.status(400).json({ error: 'Descrição muito longa.' });
  if (coverUrl && (!isHttpsUrl(coverUrl) || coverUrl.length > 2000)) return res.status(400).json({ error: 'Capa HTTPS inválida.' });
  if (episodes.length < 1 || episodes.length > 1000) return res.status(400).json({ error: 'A importação precisa conter de 1 a 1000 episódios.' });
  const normalized = [];
  const seen = new Set();
  for (const item of episodes) {
    const number = Number(item && item.number);
    const episodeTitle = String(item && item.title || '').trim();
    const sourceEpisodeId = String(item && item.sourceEpisodeId || '').trim();
    const sourceIsFree = typeof (item && item.isFree) === 'boolean' ? item.isFree : null;
    if (!Number.isSafeInteger(number) || number < 1 || number > 100000 ||
        !episodeTitle || episodeTitle.length > 180 || sourceEpisodeId.length > 180 || seen.has(number)) {
      return res.status(400).json({ error: 'A lista contém um episódio inválido ou repetido.' });
    }
    seen.add(number);
    normalized.push({ number, title: episodeTitle, sourceEpisodeId, sourceIsFree, videoUrl: '' });
  }
  normalized.sort((a, b) => a.number - b.number);
  // Conecta automaticamente somente episódios identificados como gratuitos.
  // Os episódios pagos permanecem no catálogo e recebem o link manual do administrador.
  const freeEpisodes = normalized.filter(episode => episode.sourceIsFree === true);
  for (let offset = 0; offset < freeEpisodes.length; offset += 4) {
    const batch = freeEpisodes.slice(offset, offset + 4);
    const resolved = await Promise.all(batch.map(async episode => {
      try {
        return await getReelShortVideoUrl(episode.number, sourceFilteredTitle, sourceBookId, episode.sourceEpisodeId);
      } catch (error) {
        console.warn('Não foi possível consultar o vídeo gratuito do episódio', episode.number, error.message);
        return '';
      }
    }));
    batch.forEach((episode, index) => { episode.videoUrl = resolved[index]; });
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const seriesResult = await client.query(
      `INSERT INTO catalog_series (title, synopsis, cover_url)
       VALUES ($1, $2, $3)
       ON CONFLICT (title) DO UPDATE
         SET synopsis = EXCLUDED.synopsis,
             cover_url = CASE WHEN EXCLUDED.cover_url <> '' THEN EXCLUDED.cover_url ELSE catalog_series.cover_url END
       RETURNING id, title`,
      [title, synopsis, coverUrl]
    );
    const seriesId = seriesResult.rows[0].id;
    for (const episode of normalized) {
      await client.query(
        `INSERT INTO catalog_episodes (series_id, episode_number, title, video_url, source_episode_id, source_is_free)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (series_id, episode_number) DO UPDATE
           SET title = EXCLUDED.title,
               video_url = CASE WHEN EXCLUDED.video_url <> '' THEN EXCLUDED.video_url ELSE catalog_episodes.video_url END,
               source_episode_id = EXCLUDED.source_episode_id,
               source_is_free = EXCLUDED.source_is_free`,
        [seriesId, episode.number, episode.title, episode.videoUrl, episode.sourceEpisodeId, episode.sourceIsFree]
      );
    }
    await client.query('COMMIT');
    return res.status(200).json({
      imported: true,
      series: { id: String(seriesId), title: seriesResult.rows[0].title },
      episodeCount: normalized.length,
      playback: 'authorized_urls_requested',
      videoCount: normalized.filter(episode => episode.videoUrl).length,
      videosMissing: normalized.filter(episode => !episode.videoUrl).length
    });
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Erro ao importar metadados:', error.message);
    return res.status(500).json({ error: 'Não foi possível importar a série.' });
  } finally {
    client.release();
  }
});

app.post('/admin/catalog/import-links', authRequired, async (req, res) => {
  if (req.auth.role !== 'admin') return res.status(403).json({ error: 'Acesso exclusivo do administrador.' });
  const title = String(req.body.title || '').trim();
  const synopsis = String(req.body.synopsis || '').trim();
  const coverUrl = String(req.body.coverUrl || '').trim();
  const episodes = Array.isArray(req.body.episodes) ? req.body.episodes : [];
  if (req.body.authorizedPlayback !== true) return res.status(400).json({ error: 'Confirme que possui autorização para reproduzir e distribuir os vídeos.' });
  if (!title || title.length > 180) return res.status(400).json({ error: 'Nome da novelinha inválido.' });
  if (synopsis.length > 4000) return res.status(400).json({ error: 'Sinopse muito longa.' });
  if (coverUrl && (!isHttpsUrl(coverUrl) || coverUrl.length > 2000)) return res.status(400).json({ error: 'A capa precisa ser uma URL HTTPS válida.' });
  if (episodes.length < 1 || episodes.length > 500) return res.status(400).json({ error: 'Envie de 1 a 500 episódios por importação.' });
  const normalized = [];
  const seen = new Set();
  for (const item of episodes) {
    const number = Number(item && item.number);
    const episodeTitle = String(item && item.title || '').trim();
    const videoUrl = String(item && item.videoUrl || '').trim();
    if (!Number.isSafeInteger(number) || number < 1 || number > 100000 ||
        !episodeTitle || episodeTitle.length > 180 || !isHttpsUrl(videoUrl) ||
        videoUrl.length > 8000 || seen.has(number)) {
      return res.status(400).json({ error: 'A lista contém um episódio inválido, link inseguro ou número repetido.' });
    }
    seen.add(number);
    normalized.push({ number, title: episodeTitle, videoUrl });
  }
  normalized.sort((a, b) => a.number - b.number);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const seriesResult = await client.query(
      \`INSERT INTO catalog_series (title, synopsis, cover_url)
       VALUES ($1, $2, $3)
       ON CONFLICT (title) DO UPDATE
         SET synopsis = EXCLUDED.synopsis,
             cover_url = CASE WHEN EXCLUDED.cover_url <> '' THEN EXCLUDED.cover_url ELSE catalog_series.cover_url END
       RETURNING id, title\`,
      [title, synopsis, coverUrl]
    );
    const seriesId = seriesResult.rows[0].id;
    for (const episode of normalized) {
      await client.query(
        \`INSERT INTO catalog_episodes (series_id, episode_number, title, video_url)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (series_id, episode_number) DO UPDATE
           SET title = EXCLUDED.title, video_url = EXCLUDED.video_url\`,
        [seriesId, episode.number, episode.title, episode.videoUrl]
      );
    }
    await client.query('COMMIT');
    return res.status(200).json({ imported: true, series: { id: String(seriesId), title: seriesResult.rows[0].title }, episodeCount: normalized.length });
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Erro ao importar links compartilhados:', error.message);
    return res.status(500).json({ error: 'Não foi possível importar os links.' });
  } finally {
    client.release();
  }
});

app.post('/admin/catalog/series/:seriesId/episodes', authRequired, async (req, res) => {
  if (req.auth.role !== 'admin') return res.status(403).json({ error: 'Acesso exclusivo do administrador.' });
  const seriesId = Number(req.params.seriesId);
  const number = Number(req.body.number);
  const title = String(req.body.title || '').trim();
  const videoUrl = String(req.body.videoUrl || '').trim();
  if (!Number.isSafeInteger(seriesId) || seriesId < 1) return res.status(400).json({ error: 'Série inválida.' });
  if (!Number.isSafeInteger(number) || number < 1 || number > 100000) return res.status(400).json({ error: 'Número do episódio inválido.' });
  if (!title || title.length > 180) return res.status(400).json({ error: 'Título do episódio obrigatório (até 180 caracteres).' });
  if (!isHttpsUrl(videoUrl) || videoUrl.length > 8000) return res.status(400).json({ error: 'Informe um link HTTPS válido.' });
  try {
    const result = await pool.query(
      `INSERT INTO catalog_episodes (series_id, episode_number, title, video_url)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (series_id, episode_number) DO UPDATE
         SET title = EXCLUDED.title, video_url = EXCLUDED.video_url
       RETURNING id, series_id, episode_number, title`,
      [seriesId, number, title, videoUrl]
    );
    const row = result.rows[0];
    return res.status(200).json({ episode: {
      id: String(row.id), seriesId: String(row.series_id), number: row.episode_number, title: row.title
    }});
  } catch (error) {
    if (error.code === '23503') return res.status(404).json({ error: 'Série não encontrada.' });
    console.error('Erro ao salvar episódio:', error.message);
    return res.status(500).json({ error: 'Não foi possível salvar o episódio.' });
  }
});

app.get('/admin/users', authRequired, async (req, res) => {
  if (req.auth.role !== 'admin') return res.status(403).json({ error: 'Acesso exclusivo do administrador.' });
  try {
    const result = await pool.query(
      'SELECT id, username, email, role, created_at FROM app_users ORDER BY created_at DESC LIMIT 500'
    );
    return res.json({ users: result.rows.map(user => ({
      id: String(user.id), username: user.username, email: user.email,
      role: user.role, createdAt: user.created_at
    })) });
  } catch (error) {
    console.error('Erro ao listar usuários:', error.message);
    return res.status(500).json({ error: 'Não foi possível listar os usuários.' });
  }
});

const port = Number(process.env.PORT || 3000);
initializeDatabase()
  .then(() => app.listen(port, '0.0.0.0', () => console.log(`NovelPlay API ativa na porta ${port}`)))
  .catch(error => {
    console.error('Falha ao inicializar banco:', error.message);
    process.exit(1);
  });
