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
