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
    normalized.push({ number, title: episodeTitle, sourceEpisodeId, sourceIsFree });
  }
  normalized.sort((a, b) => a.number - b.number);
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
         VALUES ($1, $2, $3, '', $4, $5)
         ON CONFLICT (series_id, episode_number) DO UPDATE
           SET title = EXCLUDED.title,
               source_episode_id = EXCLUDED.source_episode_id,
               source_is_free = EXCLUDED.source_is_free`,
        [seriesId, episode.number, episode.title, episode.sourceEpisodeId, episode.sourceIsFree]
      );
    }
    await client.query('COMMIT');
    return res.status(200).json({
      imported: true,
      series: { id: String(seriesId), title: seriesResult.rows[0].title },
      episodeCount: normalized.length,
      playback: 'metadata_only'
    });
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Erro ao importar metadados:', error.message);
    return res.status(500).json({ error: 'Não foi possível importar a série.' });
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
