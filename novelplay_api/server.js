const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { Pool } = require('pg');
const rateLimit = require('express-rate-limit');
const crypto = require('crypto');
const dns = require('dns').promises;
const net = require('net');
const { Readable, Transform } = require('stream');
const { spawn } = require('child_process');
const { google } = require('googleapis');

const app = express();
app.set('trust proxy', 1);
app.use(helmet());
app.use(cors({ origin: true }));
app.use(express.json({ limit: '2mb' }));
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
    CREATE TABLE IF NOT EXISTS google_drive_credentials (
      id SMALLINT PRIMARY KEY CHECK (id = 1),
      refresh_token_enc TEXT NOT NULL,
      refresh_token_iv TEXT NOT NULL,
      refresh_token_tag TEXT NOT NULL,
      connected_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
  await pool.query('ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_file_id TEXT');
  await pool.query('ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_upload_job_id UUID');
  await pool.query('ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_web_view_link TEXT');
  await pool.query("ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_upload_status TEXT NOT NULL DEFAULT 'not_started'");
  await pool.query("ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_upload_error TEXT NOT NULL DEFAULT ''");
  await pool.query("ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_recovery_status TEXT NOT NULL DEFAULT 'not_checked'");
  await pool.query("ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_recovery_error TEXT NOT NULL DEFAULT ''");
  await pool.query('ALTER TABLE catalog_episodes ADD COLUMN IF NOT EXISTS drive_recovery_job_id UUID');
  await pool.query("CREATE TABLE IF NOT EXISTS catalog_drive_recovery_jobs (id UUID PRIMARY KEY, status VARCHAR(32) NOT NULL DEFAULT 'queued', total_episodes INTEGER NOT NULL DEFAULT 0, completed_episodes INTEGER NOT NULL DEFAULT 0, failed_episodes INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())");
  await pool.query('CREATE TABLE IF NOT EXISTS catalog_drive_upload_jobs (id UUID PRIMARY KEY, series_id BIGINT NOT NULL REFERENCES catalog_series(id) ON DELETE CASCADE, status VARCHAR(32) NOT NULL DEFAULT \'queued\', total_episodes INTEGER NOT NULL DEFAULT 0, completed_episodes INTEGER NOT NULL DEFAULT 0, failed_episodes INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())');
  // Marca como já processados os envios criados depois da correção de áudio publicada.
  await pool.query("UPDATE catalog_episodes e SET drive_recovery_status = 'not_needed' FROM catalog_drive_upload_jobs j WHERE e.drive_upload_job_id = j.id AND j.created_at >= TIMESTAMPTZ '2026-11-10T20:29:51Z' AND e.drive_recovery_status = 'not_checked'");

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

/*
 * A role gravada no JWT é uma fotografia do momento do login.
 * Para ações administrativas, confirma-se também a role atual no banco,
 * impedindo que um token antigo continue com privilégios após uma alteração.
 */
async function adminRequired(req, res, next) {
  try {
    const result = await pool.query(
      'SELECT role FROM app_users WHERE id = $1',
      [req.auth.sub]
    );
    if (!result.rowCount) {
      return res.status(401).json({ error: 'Conta não encontrada. Entre novamente.' });
    }
    if (result.rows[0].role !== 'admin') {
      return res.status(403).json({ error: 'Acesso exclusivo do administrador.' });
    }
    req.auth.role = result.rows[0].role;
    return next();
  } catch (error) {
    console.error('Erro ao validar permissão administrativa:', error.message);
    return res.status(500).json({ error: 'Não foi possível validar a permissão administrativa.' });
  }
}


/*
 * Google Drive OAuth: o refresh token é cifrado no PostgreSQL usando uma chave
 * derivada do JWT_SECRET. Nunca devolvemos tokens ao aplicativo.
 */
const googleDriveLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 20, standardHeaders: true, legacyHeaders: false });

function googleOAuthClient() {
  // Remove espaços acidentais copiados no painel de variáveis do Render.
  const clientId = (process.env.GOOGLE_CLIENT_ID || '').trim();
  const clientSecret = (process.env.GOOGLE_CLIENT_SECRET || '').trim();
  const redirectUri = (process.env.GOOGLE_REDIRECT_URI || '').trim();
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error('Configure GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET e GOOGLE_REDIRECT_URI no Render.');
  }
  // Diagnóstico sem registrar o segredo nem qualquer parte dele.
  console.info('Diagnóstico OAuth Google Drive:', JSON.stringify({
    clientIdMatchesExpected: clientId === '722721665373-773chvkqrls0e0dmt4pqtlmcb5n7o5qr.apps.googleusercontent.com',
    clientSecretPresent: Boolean(clientSecret),
    clientSecretHasGoogleFormat: clientSecret.startsWith('GOCSPX-'),
    clientSecretLength: clientSecret.length,
    redirectUriMatchesExpected: redirectUri === 'https://novelplay-api-ee5f.onrender.com/google-drive/callback'
  }));
  return new google.auth.OAuth2(clientId, clientSecret, redirectUri);
}

function googleTokenKey() {
  return crypto.createHash('sha256').update(process.env.JWT_SECRET + ':novelplay-google-drive').digest();
}

function encryptGoogleRefreshToken(token) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', googleTokenKey(), iv);
  const encrypted = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
  return { encrypted: encrypted.toString('base64'), iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64') };
}

function decryptGoogleRefreshToken(row) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', googleTokenKey(), Buffer.from(row.refresh_token_iv, 'base64'));
  decipher.setAuthTag(Buffer.from(row.refresh_token_tag, 'base64'));
  return Buffer.concat([
    decipher.update(Buffer.from(row.refresh_token_enc, 'base64')),
    decipher.final()
  ]).toString('utf8');
}

function isPrivateAddress(address) {
  const ip = address.toLowerCase().split('%')[0];
  if (net.isIP(ip) === 4) {
    const p = ip.split('.').map(Number);
    return p[0] === 0 || p[0] === 10 || p[0] === 127 ||
      (p[0] === 100 && p[1] >= 64 && p[1] <= 127) ||
      (p[0] === 169 && p[1] === 254) ||
      (p[0] === 172 && p[1] >= 16 && p[1] <= 31) ||
      (p[0] === 192 && p[1] === 168) ||
      (p[0] === 198 && (p[1] === 18 || p[1] === 19)) || p[0] >= 224;
  }
  if (net.isIP(ip) === 6) {
    if (ip === '::' || ip === '::1' || /^f[cd]/.test(ip) ||
        /^fe[89ab]/.test(ip) || /^ff/.test(ip)) return true;
    if (ip.startsWith('::ffff:')) return isPrivateAddress(ip.slice(7));
  }
  return false;
}

async function assertPublicHttpsUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password) {
    throw new Error('O link precisa ser HTTPS público e não pode conter credenciais.');
  }
  let host = url.hostname.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  if (!host || host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) {
    throw new Error('O endereço do vídeo não é público.');
  }
  const addresses = net.isIP(host) ? [{ address: host }] : await dns.lookup(host, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(item => isPrivateAddress(item.address))) {
    throw new Error('O endereço do vídeo não pode apontar para uma rede privada.');
  }
  return url;
}

async function googleDriveClient() {
  const stored = await pool.query('SELECT refresh_token_enc, refresh_token_iv, refresh_token_tag FROM google_drive_credentials WHERE id = 1');
  if (!stored.rowCount) throw new Error('Conecte o Google Drive antes de importar episódios.');
  const oauth2 = googleOAuthClient();
  oauth2.setCredentials({ refresh_token: decryptGoogleRefreshToken(stored.rows[0]) });
  return google.drive({ version: 'v3', auth: oauth2 });
}

async function findOrCreateDriveFolder(drive, name, parentId) {
  const escaped = name.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  const parentClause = parentId ? "'" + parentId + "' in parents and " : '';
  const found = await drive.files.list({
    q: parentClause + "name = '" + escaped + "' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
    pageSize: 10,
    fields: 'files(id,name)'
  });
  if (found.data.files && found.data.files.length) return found.data.files[0].id;
  const body = { name: name, mimeType: 'application/vnd.google-apps.folder' };
  if (parentId) body.parents = [parentId];
  const created = await drive.files.create({ requestBody: body, fields: 'id,name' });
  return created.data.id;
}

async function resolveHighestHlsVariant(sourceUrl) {
  let playlistUrl = new URL(sourceUrl);
  for (let depth = 0; depth < 5; depth++) {
    await assertPublicHttpsUrl(playlistUrl.toString());
    let response;
    for (let redirects = 0; redirects <= 5; redirects++) {
      response = await fetch(playlistUrl, {
        redirect: 'manual',
        headers: {
          'User-Agent': 'NovelPlay/1.0 authorized media transfer',
          'Accept': 'application/vnd.apple.mpegurl, application/x-mpegURL, */*'
        },
        signal: AbortSignal.timeout(30000)
      });
      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const location = response.headers.get('location');
      if (!location) throw new Error('Playlist HLS redirecionada sem destino.');
      playlistUrl = new URL(location, playlistUrl);
      await assertPublicHttpsUrl(playlistUrl.toString());
    }
    if (!response || !response.ok) {
      throw new Error('Não foi possível consultar a playlist HLS (HTTP ' + (response ? response.status : 'desconhecido') + ').');
    }
    const body = await response.text();
    if (body.length > 2 * 1024 * 1024) throw new Error('Playlist HLS excede o tamanho permitido.');
    const lines = body.split(/\r?\n/);
    const variants = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      const attrs = line.slice('#EXT-X-STREAM-INF:'.length);
      const resolution = attrs.match(/(?:^|,)RESOLUTION=(\d+)x(\d+)/i);
      const bandwidth = attrs.match(/(?:^|,)(?:AVERAGE-BANDWIDTH|BANDWIDTH)=(\d+)/i);
      let uri = '';
      for (let j = i + 1; j < lines.length; j++) {
        const candidate = lines[j].trim();
        if (candidate && !candidate.startsWith('#')) { uri = candidate; break; }
      }
      if (!uri) continue;
      const width = resolution ? Number(resolution[1]) : 0;
      const height = resolution ? Number(resolution[2]) : 0;
      variants.push({
        url: new URL(uri, playlistUrl).toString(),
        pixels: width * height,
        bandwidth: bandwidth ? Number(bandwidth[1]) : 0
      });
    }
    if (!variants.length) return playlistUrl.toString();
    variants.sort((a, b) => b.pixels - a.pixels || b.bandwidth - a.bandwidth);
    playlistUrl = new URL(variants[0].url);
  }
  throw new Error('A playlist HLS possui redirecionamentos de qualidade em excesso.');
}

async function uploadHlsEpisode(drive, sourceUrl, folderId, number) {
  // Preserve the master playlist: some HLS streams keep audio in a separate
  // EXT-X-MEDIA rendition. Selecting only a video variant drops that audio.
  // FFmpeg reads the master playlist and can mux its linked audio rendition.
  const hlsSourceUrl = sourceUrl;
  const fileName = 'Episódio ' + String(number).padStart(3, '0') + '.mp4';
  const child = spawn('ffmpeg', [
    '-hide_banner', '-nostdin', '-loglevel', 'warning', '-threads', '1',
    '-protocol_whitelist', 'https,tls,tcp,crypto,data',
    '-user_agent', 'NovelPlay/1.0 authorized media transfer',
    '-i', hlsSourceUrl,
    // Não envia um arquivo silenciosamente sem áudio: a faixa é obrigatória.
    '-map', '0:v:0', '-map', '0:a:0',
    // Mantém o vídeo original (resolução/bitrate/qualidade) e padroniza só o áudio.
    '-c:v', 'copy',
    '-c:a', 'aac', '-b:a', '192k',
    '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
    '-f', 'mp4', 'pipe:1'
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  let outputBytes = 0;
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8000); });
  const limitedOutput = new Transform({
    transform(chunk, encoding, callback) {
      outputBytes += chunk.length;
      if (outputBytes > 2 * 1024 * 1024 * 1024) {
        callback(new Error('O vídeo convertido ultrapassa o limite de 2 GB por episódio.'));
        child.kill('SIGKILL');
      } else callback(null, chunk);
    }
  });
  child.stdout.pipe(limitedOutput);
  const closePromise = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(('Falha ao converter playlist HLS: ' + (stderr.trim() || ('FFmpeg encerrou com código ' + code + (signal ? ' (' + signal + ')' : '')))).slice(0, 500)));
    });
  });
  try {
    const uploadPromise = drive.files.create({
      requestBody: { name: fileName, mimeType: 'video/mp4', parents: [folderId] },
      media: { mimeType: 'video/mp4', body: limitedOutput },
      fields: 'id,name,mimeType,size,webViewLink'
    });
    const [uploaded] = await Promise.all([uploadPromise, closePromise]);
    return uploaded.data;
  } catch (error) {
    child.kill('SIGKILL');
    limitedOutput.destroy();
    throw error;
  }
}
async function downloadAndUploadEpisode(drive, sourceUrl, folderId, number) {
  let current = new URL(sourceUrl);
  let response;
  for (let redirects = 0; redirects <= 5; redirects++) {
    await assertPublicHttpsUrl(current.toString());
    response = await fetch(current, {
      redirect: 'manual',
      headers: { 'User-Agent': 'NovelPlay/1.0 authorized media transfer', 'Accept': 'video/*,application/octet-stream,*/*' },
      signal: AbortSignal.timeout(30 * 60 * 1000)
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      if (!location) throw new Error('O servidor do vídeo redirecionou sem informar o destino.');
      current = new URL(location, current);
      continue;
    }
    break;
  }
  if (!response || [301, 302, 303, 307, 308].includes(response.status)) {
    throw new Error('O link excedeu o limite de redirecionamentos.');
  }
  if (!response.ok || !response.body) throw new Error('Não foi possível baixar o vídeo (HTTP ' + response.status + ').');
  const sourceMimeType = (response.headers.get('content-type') || 'application/octet-stream').split(';')[0].trim().toLowerCase();
  const isHls = sourceMimeType.includes('mpegurl') || /\\.m3u8(?:$|[?])/i.test(current.pathname);
  if (isHls) {
    await response.body.cancel().catch(() => {});
    return uploadHlsEpisode(drive, current.toString(), folderId, number);
  }
  if (sourceMimeType === 'text/html' || sourceMimeType.includes('json') || sourceMimeType.startsWith('text/')) {
    await response.body.cancel().catch(() => {});
    throw new Error('O link não retornou um arquivo de vídeo direto. Use um link de download válido.');
  }
  // Muitos servidores de hospedagem entregam MP4 como application/octet-stream.
  // Como os episódios são gravados com extensão .mp4, informe explicitamente
  // video/mp4 ao Google Drive para habilitar a pré-visualização de vídeo.
  const disposition = response.headers.get('content-disposition') || '';
  const isMp4Source = /\\.mp4(?:$|[?;])/i.test(current.pathname) || /filename[^;]*\\.mp4/i.test(disposition);
  let mimeType = sourceMimeType;
  if (sourceMimeType === 'application/octet-stream' || sourceMimeType === 'application/mp4' || !sourceMimeType) {
    mimeType = 'video/mp4';
  } else if (!sourceMimeType.startsWith('video/')) {
    await response.body.cancel().catch(() => {});
    throw new Error('O link retornou um tipo de arquivo que não é vídeo (' + sourceMimeType + ').');
  }
  if (isMp4Source && mimeType === 'application/octet-stream') mimeType = 'video/mp4';
  const length = Number(response.headers.get('content-length') || 0);
  if (length > 2 * 1024 * 1024 * 1024) {
    await response.body.cancel().catch(() => {});
    throw new Error('O vídeo ultrapassa o limite de 2 GB por episódio.');
  }
  const fileName = 'Episódio ' + String(number).padStart(3, '0') + '.mp4';
  const uploaded = await drive.files.create({
    requestBody: { name: fileName, mimeType: mimeType, parents: [folderId] },
    media: { mimeType: mimeType, body: Readable.fromWeb(response.body) },
    fields: 'id,name,mimeType,size,webViewLink'
  });
  return uploaded.data;
}

async function processDriveUploadJob(jobId) {
  const claimed = await pool.query(
    "UPDATE catalog_drive_upload_jobs SET status = 'running', updated_at = NOW() WHERE id = $1 AND status = 'queued' RETURNING id, series_id",
    [jobId]
  );
  if (!claimed.rowCount) return;
  try {
    const job = claimed.rows[0];
    const seriesResult = await pool.query('SELECT title FROM catalog_series WHERE id = $1', [job.series_id]);
    if (!seriesResult.rowCount) throw new Error('A novelinha não foi encontrada.');
    const drive = await googleDriveClient();
    const rootFolder = await findOrCreateDriveFolder(drive, 'NovelPlay', null);
    const seriesFolder = await findOrCreateDriveFolder(drive, seriesResult.rows[0].title, rootFolder);
    const episodes = await pool.query(
      "SELECT id, episode_number, video_url FROM catalog_episodes WHERE drive_upload_job_id = $1 AND drive_upload_status = 'queued' ORDER BY episode_number",
      [jobId]
    );
    for (const episode of episodes.rows) {
      await pool.query("UPDATE catalog_episodes SET drive_upload_status = 'uploading', drive_upload_error = '' WHERE id = $1", [episode.id]);
      try {
        const file = await downloadAndUploadEpisode(drive, episode.video_url, seriesFolder, episode.episode_number);
        await pool.query(
          "UPDATE catalog_episodes SET drive_file_id = $2, drive_web_view_link = $3, drive_upload_status = 'uploaded', drive_upload_error = '', drive_recovery_status = 'not_needed', drive_recovery_error = '' WHERE id = $1",
          [episode.id, file.id, file.webViewLink || '']
        );
        await pool.query("UPDATE catalog_drive_upload_jobs SET completed_episodes = completed_episodes + 1, updated_at = NOW() WHERE id = $1", [jobId]);
      } catch (error) {
        const message = String(error.message || 'Falha ao enviar o vídeo').slice(0, 500);
        console.warn('Falha no envio ao Drive do episódio ' + episode.episode_number + ':', message);
        await pool.query("UPDATE catalog_episodes SET drive_upload_status = 'failed', drive_upload_error = $2 WHERE id = $1", [episode.id, message]);
        await pool.query("UPDATE catalog_drive_upload_jobs SET failed_episodes = failed_episodes + 1, updated_at = NOW() WHERE id = $1", [jobId]);
      }
    }
    const counts = await pool.query(
      "SELECT COUNT(*) FILTER (WHERE drive_upload_status = 'uploaded')::int AS uploaded, COUNT(*) FILTER (WHERE drive_upload_status = 'failed')::int AS failed FROM catalog_episodes WHERE drive_upload_job_id = $1",
      [jobId]
    );
    const uploaded = counts.rows[0].uploaded;
    const failed = counts.rows[0].failed;
    await pool.query(
      'UPDATE catalog_drive_upload_jobs SET status = $2, completed_episodes = $3, failed_episodes = $4, updated_at = NOW() WHERE id = $1',
      [jobId, failed ? 'completed_with_errors' : 'completed', uploaded, failed]
    );
  } catch (error) {
    console.error('Erro ao processar envio ao Google Drive:', error.message);
    await pool.query("UPDATE catalog_drive_upload_jobs SET status = 'failed', updated_at = NOW() WHERE id = $1", [jobId]).catch(() => {});
    await pool.query(
      "UPDATE catalog_episodes SET drive_upload_status = 'failed', drive_upload_error = $2 WHERE drive_upload_job_id = $1 AND drive_upload_status IN ('queued', 'uploading')",
      [jobId, String(error.message || 'Falha no envio ao Drive').slice(0, 500)]
    ).catch(() => {});
  }
}


/*
 * Recupera arquivos já existentes no Drive. O arquivo é atualizado pelo ID,
 * portanto o link compartilhado permanece o mesmo; o vídeo é copiado sem
 * reencodificação e somente o áudio é convertido para AAC.
 */
async function replaceDriveFileFromSource(drive, sourceUrl, fileId, number) {
  await assertPublicHttpsUrl(sourceUrl);
  const child = spawn('ffmpeg', [
    '-hide_banner', '-nostdin', '-loglevel', 'warning', '-threads', '1',
    '-protocol_whitelist', 'https,http,tls,tcp,crypto,data',
    '-user_agent', 'NovelPlay/1.0 authorized media transfer',
    '-i', sourceUrl,
    '-map', '0:v:0', '-map', '0:a:0',
    '-c:v', 'copy',
    '-c:a', 'aac', '-b:a', '192k',
    '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
    '-f', 'mp4', 'pipe:1'
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  let outputBytes = 0;
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8000); });
  const limitedOutput = new Transform({
    transform(chunk, encoding, callback) {
      outputBytes += chunk.length;
      if (outputBytes > 2 * 1024 * 1024 * 1024) {
        callback(new Error('O vídeo convertido ultrapassa o limite de 2 GB por episódio.'));
        child.kill('SIGKILL');
      } else callback(null, chunk);
    }
  });
  child.stdout.pipe(limitedOutput);
  const closePromise = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(('Falha ao recuperar episódio ' + number + ': ' +
        (stderr.trim() || ('FFmpeg encerrou com código ' + code + (signal ? ' (' + signal + ')' : '')))).slice(0, 500)));
    });
  });
  try {
    const updatePromise = drive.files.update({
      fileId,
      requestBody: { mimeType: 'video/mp4' },
      media: { mimeType: 'video/mp4', body: limitedOutput },
      fields: 'id,name,mimeType,size,webViewLink'
    });
    const [updated] = await Promise.all([updatePromise, closePromise]);
    const metadata = updated.data || {};
    if (metadata.mimeType !== 'video/mp4' || !(Number(metadata.size) > 0)) {
      throw new Error('O Google Drive não confirmou um vídeo MP4 válido após a substituição.');
    }
    // O mapeamento obrigatório -map 0:a:0 acima faz o FFmpeg falhar se a origem
    // não tiver faixa de áudio; só marcamos como recuperado após a conversão
    // terminar e o Drive confirmar o arquivo atualizado.
    return metadata;
  } catch (error) {
    child.kill('SIGKILL');
    limitedOutput.destroy();
    throw error;
  }
}

async function processDriveRecoveryJob(jobId) {
  const claimed = await pool.query(
    "UPDATE catalog_drive_recovery_jobs SET status = 'running', updated_at = NOW() WHERE id = $1 AND status = 'queued' RETURNING id",
    [jobId]
  );
  if (!claimed.rowCount) return;
  try {
    const episodes = await pool.query(
      "SELECT e.id, e.episode_number, e.video_url, e.drive_file_id FROM catalog_episodes e WHERE e.drive_recovery_job_id = $1 AND e.drive_recovery_status = 'queued' ORDER BY e.id",
      [jobId]
    );
    const drive = await googleDriveClient();
    for (const episode of episodes.rows) {
      await pool.query("UPDATE catalog_episodes SET drive_recovery_status = 'recovering', drive_recovery_error = '' WHERE id = $1", [episode.id]);
      try {
        if (!episode.drive_file_id || !episode.video_url) throw new Error('Falta o ID do arquivo no Drive ou o link original do episódio.');
        await replaceDriveFileFromSource(drive, episode.video_url, episode.drive_file_id, episode.episode_number);
        await pool.query("UPDATE catalog_episodes SET drive_recovery_status = 'recovered', drive_recovery_error = '' WHERE id = $1", [episode.id]);
        await pool.query("UPDATE catalog_drive_recovery_jobs SET completed_episodes = completed_episodes + 1, updated_at = NOW() WHERE id = $1", [jobId]);
      } catch (error) {
        const message = String(error.message || 'Falha ao recuperar o episódio').slice(0, 500);
        console.warn('Falha na recuperação do episódio ' + episode.episode_number + ':', message);
        await pool.query("UPDATE catalog_episodes SET drive_recovery_status = 'failed', drive_recovery_error = $2 WHERE id = $1", [episode.id, message]);
        await pool.query("UPDATE catalog_drive_recovery_jobs SET failed_episodes = failed_episodes + 1, updated_at = NOW() WHERE id = $1", [jobId]);
      }
    }
    const counts = await pool.query(
      "SELECT COUNT(*) FILTER (WHERE drive_recovery_status = 'recovered')::int AS recovered, COUNT(*) FILTER (WHERE drive_recovery_status = 'failed')::int AS failed FROM catalog_episodes WHERE drive_recovery_job_id = $1",
      [jobId]
    );
    const recovered = counts.rows[0].recovered;
    const failed = counts.rows[0].failed;
    await pool.query(
      'UPDATE catalog_drive_recovery_jobs SET status = $2, completed_episodes = $3, failed_episodes = $4, updated_at = NOW() WHERE id = $1',
      [jobId, failed ? 'completed_with_errors' : 'completed', recovered, failed]
    );
  } catch (error) {
    console.error('Erro no lote de recuperação do Google Drive:', error.message);
    await pool.query("UPDATE catalog_drive_recovery_jobs SET status = 'failed', updated_at = NOW() WHERE id = $1", [jobId]).catch(() => {});
    await pool.query(
      "UPDATE catalog_episodes SET drive_recovery_status = 'failed', drive_recovery_error = $2 WHERE drive_recovery_job_id = $1 AND drive_recovery_status IN ('queued', 'recovering')",
      [jobId, String(error.message || 'Falha na recuperação').slice(0, 500)]
    ).catch(() => {});
  }
}


const driveVerificationJobs = new Map();

async function verifyDriveEpisode(drive, episode) {
  const fileId = String(episode.drive_file_id || '').trim();
  if (!fileId) throw new Error('ID do arquivo do Drive ausente.');
  const metadataResponse = await drive.files.get({
    fileId,
    fields: 'id,name,mimeType,size,trashed,videoMediaMetadata'
  });
  const metadata = metadataResponse.data || {};
  if (metadata.trashed) throw new Error('O arquivo está na lixeira do Google Drive.');
  if (metadata.mimeType !== 'video/mp4') {
    throw new Error('Tipo incorreto no Drive: ' + String(metadata.mimeType || 'desconhecido') + '. Esperado video/mp4.');
  }
  if (!Number(metadata.size || 0)) throw new Error('O arquivo aparece vazio no Google Drive.');
  if (!metadata.videoMediaMetadata || !Number(metadata.videoMediaMetadata.durationMillis || 0)) {
    throw new Error('O Google Drive não reconheceu a duração do vídeo.');
  }

  // Baixa o conteúdo do Drive e decodifica vídeo E áudio. A verificação não
  // altera nem substitui o arquivo; ela só confirma que as duas faixas podem
  // ser lidas integralmente pelo FFmpeg.
  const mediaResponse = await drive.files.get(
    { fileId, alt: 'media' },
    { responseType: 'stream' }
  );
  const child = spawn('ffmpeg', [
    '-hide_banner', '-nostdin', '-v', 'error', '-xerror',
    // Limita a memória usada pelos decodificadores em servidores pequenos.
    // Sem isso, o FFmpeg pode criar várias threads por núcleo e esgotar os
    // 512 MB do serviço ao validar vídeos em alta resolução.
    '-threads', '1',
    '-filter_threads', '1',
    '-filter_complex_threads', '1',
    '-probesize', '2M',
    '-analyzeduration', '2M',
    '-max_alloc', '67108864',
    '-i', 'pipe:0',
    '-threads', '1',
    '-map', '0:v:0', '-map', '0:a:0',
    '-f', 'null', '-'
  ], { stdio: ['pipe', 'ignore', 'pipe'] });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-6000); });
  const closePromise = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (exitCode, signal) => {
      if (exitCode === 0) resolve();
      else reject(new Error(stderr.trim() || ('FFmpeg não conseguiu validar as faixas de áudio e vídeo (código ' + exitCode + (signal ? ', ' + signal : '') + ').')));
    });
  });
  mediaResponse.data.on('error', error => child.stdin.destroy(error));
  mediaResponse.data.pipe(child.stdin);
  try {
    await closePromise;
  } catch (error) {
    child.kill('SIGKILL');
    throw error;
  }
  return {
    status: 'ok',
    fileName: metadata.name || '',
    mimeType: metadata.mimeType,
    size: Number(metadata.size),
    durationMillis: Number(metadata.videoMediaMetadata.durationMillis),
    hasVideo: true,
    hasAudio: true
  };
}

async function processDriveVerificationJob(jobId) {
  const job = driveVerificationJobs.get(jobId);
  if (!job) return;
  job.status = 'running';
  try {
    const result = await pool.query(
      'SELECT e.id, s.title AS series_title, e.episode_number, e.drive_file_id FROM catalog_episodes e JOIN catalog_series s ON s.id = e.series_id WHERE LENGTH(BTRIM(COALESCE(e.drive_file_id, CHR(32)))) > 0 ORDER BY s.title, e.episode_number'
    );
    job.total = result.rows.length;
    const drive = await googleDriveClient();
    for (const episode of result.rows) {
      const item = {
        id: String(episode.id),
        seriesTitle: episode.series_title,
        episodeNumber: episode.episode_number
      };
      try {
        const checked = await verifyDriveEpisode(drive, episode);
        job.ok++;
        job.results.push({ ...item, ...checked, message: 'Vídeo e áudio íntegros.' });
      } catch (error) {
        job.failed++;
        job.results.push({
          ...item,
          status: 'failed',
          message: String(error.message || 'Falha ao verificar o vídeo.').slice(0, 500)
        });
      }
      job.checked++;
      job.updatedAt = new Date().toISOString();
    }
    job.status = job.failed ? 'completed_with_errors' : 'completed';
  } catch (error) {
    job.status = 'failed';
    job.error = String(error.message || 'Não foi possível verificar o Google Drive.').slice(0, 500);
  }
  job.updatedAt = new Date().toISOString();
}

app.post('/admin/google-drive/verify', authRequired, adminRequired, async (_req, res) => {
  try {
    const connected = await pool.query('SELECT id FROM google_drive_credentials WHERE id = 1');
    if (!connected.rowCount) return res.status(409).json({ error: 'Conecte o Google Drive antes de verificar os vídeos.' });
    const active = Array.from(driveVerificationJobs.values()).find(job =>
      ['queued', 'running'].includes(job.status));
    if (active) return res.status(409).json({ error: 'Já existe uma verificação em andamento.', jobId: active.id });
    const id = crypto.randomUUID();
    driveVerificationJobs.set(id, {
      id, status: 'queued', total: 0, checked: 0, ok: 0, failed: 0,
      results: [], createdAt: new Date().toISOString(), updatedAt: new Date().toISOString()
    });
    setImmediate(() => processDriveVerificationJob(id));
    return res.status(202).json({ jobId: id, status: 'queued' });
  } catch (error) {
    console.error('Erro ao iniciar verificação do Google Drive:', error.message);
    return res.status(500).json({ error: 'Não foi possível iniciar a verificação dos vídeos.' });
  }
});

app.get('/admin/google-drive/verify/:jobId', authRequired, adminRequired, async (req, res) => {
  const id = String(req.params.jobId || '');
  const job = driveVerificationJobs.get(id);
  if (!job) return res.status(404).json({ error: 'Verificação não encontrada. Se o servidor reiniciou, inicie uma nova verificação.' });
  return res.json({
    jobId: job.id, status: job.status, total: job.total, checked: job.checked,
    ok: job.ok, failed: job.failed, error: job.error || null,
    updatedAt: job.updatedAt, results: job.results
  });
});

app.get('/admin/google-drive/recovery/preview', authRequired, adminRequired, async (_req, res) => {
  try {
    // Diagnóstico inclui todos os episódios, não apenas os já marcados como recuperáveis.
    const result = await pool.query(`
      SELECT e.id, s.title AS series_title, e.episode_number, e.drive_file_id,
             e.video_url, e.drive_recovery_status, e.drive_recovery_error
      FROM catalog_episodes e
      JOIN catalog_series s ON s.id = e.series_id
      WHERE NULLIF(BTRIM(e.drive_file_id), '') IS NOT NULL
      ORDER BY s.title, e.episode_number
      LIMIT 1000
    `);
    const items = result.rows.map(row => ({
      id: String(row.id),
      seriesTitle: row.series_title,
      episodeNumber: row.episode_number,
      hasDriveFile: Boolean(String(row.drive_file_id || '').trim()),
      hasSourceUrl: Boolean(String(row.video_url || '').trim()),
      recoveryStatus: row.drive_recovery_status || 'not_checked',
      recoveryError: row.drive_recovery_error || ''
    }));
    const eligible = items.filter(item => item.hasSourceUrl &&
      ['not_checked', 'failed'].includes(item.recoveryStatus));
    return res.json({
      items,
      totalWithDriveFile: items.length,
      eligible: eligible.length,
      missingSource: items.filter(item => !item.hasSourceUrl).length,
      recovered: items.filter(item => item.recoveryStatus === 'recovered').length,
      ignoredStatus: items.filter(item =>
        !['not_checked', 'failed', 'recovered'].includes(item.recoveryStatus)).length,
      failed: items.filter(item => item.recoveryStatus === 'failed').length
    });
  } catch (error) {
    console.error('Erro ao preparar prévia da recuperação:', error.message);
    return res.status(500).json({ error: 'Não foi possível preparar a lista de episódios recuperáveis.' });
  }
});

app.post('/admin/google-drive/recovery', authRequired, adminRequired, async (req, res) => {
  const episodeIds = Array.isArray(req.body.episodeIds) ? req.body.episodeIds : [];
  if (!episodeIds.length || episodeIds.length > 100 ||
      episodeIds.some(id => !/^\d+$/.test(String(id)))) {
    return res.status(400).json({ error: 'Selecione de 1 a 100 episódios válidos.' });
  }
  const ids = Array.from(new Set(episodeIds.map(String)));
  try {
    const connected = await pool.query('SELECT id FROM google_drive_credentials WHERE id = 1');
    if (!connected.rowCount) return res.status(409).json({ error: 'Conecte o Google Drive antes de recuperar episódios.' });

    // Revalida cada item no banco e bloqueia as linhas durante a criação do lote.
    // Itens sem origem/arquivo, já recuperados ou em processamento são ignorados,
    // em vez de impedir a recuperação dos demais episódios selecionados.
    const client = await pool.connect();
    let jobId;
    let eligibleIds = [];
    try {
      await client.query('BEGIN');
      const eligible = await client.query(
        "SELECT id FROM catalog_episodes WHERE id = ANY($1::bigint[]) AND NULLIF(BTRIM(drive_file_id), '') IS NOT NULL AND NULLIF(BTRIM(video_url), '') IS NOT NULL AND drive_recovery_status IN ('not_checked', 'failed') ORDER BY id FOR UPDATE",
        [ids]
      );
      eligibleIds = eligible.rows.map(row => String(row.id));
      const skipped = ids.length - eligibleIds.length;
      if (!eligibleIds.length) {
        await client.query('ROLLBACK');
        return res.status(409).json({
          error: 'Nenhum dos episódios selecionados ainda está disponível para recuperação. Consulte novamente a lista de episódios recuperáveis.',
          skipped
        });
      }

      jobId = crypto.randomUUID();
      await client.query(
        "INSERT INTO catalog_drive_recovery_jobs (id, status, total_episodes) VALUES ($1, 'queued', $2)",
        [jobId, eligibleIds.length]
      );
      await client.query(
        "UPDATE catalog_episodes SET drive_recovery_status = 'queued', drive_recovery_error = '', drive_recovery_job_id = $2 WHERE id = ANY($1::bigint[])",
        [eligibleIds, jobId]
      );
      await client.query('COMMIT');
      res.status(202).json({
        jobId, status: 'queued', total: eligibleIds.length, skipped
      });
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally {
      client.release();
    }
    setImmediate(() => processDriveRecoveryJob(jobId));
  } catch (error) {
    console.error('Erro ao iniciar recuperação do Drive:', error.message);
    return res.status(500).json({ error: 'Não foi possível iniciar a recuperação dos episódios.' });
  }
});

app.get('/admin/google-drive/recovery/:jobId', authRequired, adminRequired, async (req, res) => {
  const jobId = String(req.params.jobId || '');
  if (!/^[0-9a-f-]{36}$/i.test(jobId)) return res.status(400).json({ error: 'Lote de recuperação inválido.' });
  try {
    const result = await pool.query(
      'SELECT id, status, total_episodes, completed_episodes, failed_episodes FROM catalog_drive_recovery_jobs WHERE id = $1',
      [jobId]
    );
    if (!result.rowCount) return res.status(404).json({ error: 'Lote de recuperação não encontrado.' });
    const row = result.rows[0];
    const episodeResults = await pool.query(
      `SELECT s.title AS series_title, e.episode_number,
              e.drive_recovery_status, e.drive_recovery_error
       FROM catalog_episodes e
       JOIN catalog_series s ON s.id = e.series_id
       WHERE e.drive_recovery_job_id = $1
       ORDER BY s.title, e.episode_number`,
      [jobId]
    );
    return res.json({
      jobId: row.id, status: row.status, total: row.total_episodes,
      recovered: row.completed_episodes, failed: row.failed_episodes,
      pending: Math.max(0, row.total_episodes - row.completed_episodes - row.failed_episodes),
      episodes: episodeResults.rows.map(item => ({
        seriesTitle: item.series_title,
        episodeNumber: item.episode_number,
        status: item.drive_recovery_status,
        error: item.drive_recovery_error || ''
      }))
    });
  } catch (error) {
    console.error('Erro ao consultar lote de recuperação:', error.message);
    return res.status(500).json({ error: 'Não foi possível consultar o progresso da recuperação.' });
  }
});

app.get('/admin/google-drive/connect', authRequired, adminRequired, googleDriveLimiter, async (req, res) => {
  try {
    const oauth2 = googleOAuthClient();
    const state = jwt.sign(
      { purpose: 'google-drive-oauth', adminId: String(req.auth.sub) },
      process.env.JWT_SECRET,
      { expiresIn: '10m', issuer: 'novelplay-api', audience: 'novelplay-google-drive' }
    );
    const authorizationUrl = oauth2.generateAuthUrl({
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: true,
      scope: ['https://www.googleapis.com/auth/drive'],
      state
    });
    return res.json({ authorizationUrl });
  } catch (error) {
    console.error('Erro ao iniciar conexão com Google Drive:', error.message);
    return res.status(503).json({ error: error.message });
  }
});

app.get('/google-drive/callback', googleDriveLimiter, async (req, res) => {
  try {
    if (req.query.error) return res.status(400).send('A autorização do Google Drive foi cancelada ou recusada. Você pode fechar esta página.');
    const state = jwt.verify(String(req.query.state || ''), process.env.JWT_SECRET, {
      issuer: 'novelplay-api',
      audience: 'novelplay-google-drive'
    });
    if (state.purpose !== 'google-drive-oauth' || !state.adminId || !req.query.code) {
      return res.status(400).send('Resposta OAuth inválida. Inicie a conexão novamente pelo painel do NovelPlay.');
    }
    const oauth2 = googleOAuthClient();
    const { tokens } = await oauth2.getToken(String(req.query.code));
    if (!tokens.refresh_token) {
      return res.status(400).send('O Google não forneceu um token de atualização. Revogue o acesso do NovelPlay na sua Conta Google e tente conectar novamente.');
    }
    const encrypted = encryptGoogleRefreshToken(tokens.refresh_token);
    await pool.query(
      `INSERT INTO google_drive_credentials
         (id, refresh_token_enc, refresh_token_iv, refresh_token_tag, connected_at)
       VALUES (1, $1, $2, $3, NOW())
       ON CONFLICT (id) DO UPDATE SET
         refresh_token_enc = EXCLUDED.refresh_token_enc,
         refresh_token_iv = EXCLUDED.refresh_token_iv,
         refresh_token_tag = EXCLUDED.refresh_token_tag,
         connected_at = NOW()`,
      [encrypted.encrypted, encrypted.iv, encrypted.tag]
    );
    return res.status(200).send('<!doctype html><html lang="pt-br"><meta charset="utf-8"><title>NovelPlay conectado</title><body style="font-family:Arial,sans-serif;padding:32px"><h2>Google Drive conectado ao NovelPlay!</h2><p>Você já pode fechar esta página e voltar ao aplicativo.</p></body></html>');
  } catch (error) {
    console.error('Erro no retorno OAuth do Google Drive:', error.message);
    return res.status(400).send('Não foi possível concluir a conexão com o Google Drive. Verifique a configuração OAuth e tente novamente.');
  }
});

app.get('/admin/google-drive/status', authRequired, adminRequired, async (_req, res) => {
  try {
    const result = await pool.query('SELECT connected_at FROM google_drive_credentials WHERE id = 1');
    return res.json({ connected: result.rowCount > 0, connectedAt: result.rows[0]?.connected_at || null });
  } catch (error) {
    console.error('Erro ao consultar conexão Google Drive:', error.message);
    return res.status(500).json({ error: 'Não foi possível consultar a conexão com o Google Drive.' });
  }
});

app.get('/admin/google-drive/files', authRequired, adminRequired, async (req, res) => {
  try {
    const stored = await pool.query('SELECT refresh_token_enc, refresh_token_iv, refresh_token_tag FROM google_drive_credentials WHERE id = 1');
    if (!stored.rowCount) return res.status(409).json({ error: 'Google Drive ainda não conectado.' });
    const oauth2 = googleOAuthClient();
    oauth2.setCredentials({ refresh_token: decryptGoogleRefreshToken(stored.rows[0]) });
    const drive = google.drive({ version: 'v3', auth: oauth2 });
    const pageSize = Math.min(Math.max(Number(req.query.pageSize) || 100, 1), 1000);
    const pageToken = String(req.query.pageToken || '');
    const response = await drive.files.list({
      pageSize,
      pageToken: pageToken || undefined,
      q: 'trashed = false',
      orderBy: 'folder,name',
      fields: 'nextPageToken,files(id,name,mimeType,mimeType,parents,webViewLink,thumbnailLink,size,modifiedTime)'
    });
    return res.json({ files: response.data.files || [], nextPageToken: response.data.nextPageToken || null });
  } catch (error) {
    console.error('Erro ao listar arquivos do Google Drive:', error.message);
    return res.status(502).json({ error: 'Não foi possível listar os arquivos do Google Drive.' });
  }
});

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

app.post('/admin/catalog/series', authRequired, adminRequired, async (req, res) => {
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

app.post('/admin/catalog/import', authRequired, adminRequired, async (req, res) => {
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

app.post('/admin/catalog/import-links', authRequired, adminRequired, async (req, res) => {
  const title = String(req.body.title || '').trim();
  const synopsis = String(req.body.synopsis || '').trim();
  const coverUrl = String(req.body.coverUrl || '').trim();
  const episodes = Array.isArray(req.body.episodes) ? req.body.episodes : [];
  if (req.body.authorizedPlayback !== true) return res.status(400).json({ error: 'Confirme que possui autorização para armazenar e reproduzir estes vídeos.' });
  if (!title || title.length > 180) return res.status(400).json({ error: 'Nome da novelinha inválido.' });
  if (synopsis.length > 4000) return res.status(400).json({ error: 'Sinopse muito longa.' });
  if (coverUrl && (!isHttpsUrl(coverUrl) || coverUrl.length > 2000)) return res.status(400).json({ error: 'A capa precisa ser uma URL HTTPS válida.' });
  if (episodes.length < 1 || episodes.length > 500) return res.status(400).json({ error: 'Envie de 1 a 500 episódios por importação.' });
  const normalized = [];
  const seenNumbers = new Set();
  const seenUrls = new Set();
  let duplicateCount = 0;
  for (const item of episodes) {
    const number = Number(item && item.number);
    const episodeTitle = String(item && item.title || '').trim();
    const videoUrl = String(item && item.videoUrl || '').trim();
    if (!Number.isSafeInteger(number) || number < 1 || number > 100000 ||
        !episodeTitle || episodeTitle.length > 180 || !isHttpsUrl(videoUrl) ||
        videoUrl.length > 8000 || seenNumbers.has(number)) {
      return res.status(400).json({ error: 'A lista contém um episódio inválido, link inseguro ou número repetido.' });
    }
    seenNumbers.add(number);
    let urlKey;
    try {
      const parsed = new URL(videoUrl);
      parsed.hash = '';
      urlKey = parsed.toString();
    } catch (_) {
      return res.status(400).json({ error: 'Um dos links informados é inválido.' });
    }
    if (seenUrls.has(urlKey)) {
      duplicateCount++;
      continue;
    }
    seenUrls.add(urlKey);
    normalized.push({ number: number, title: episodeTitle, videoUrl: videoUrl, urlKey: urlKey });
  }
  normalized.sort((a, b) => a.number - b.number);
  if (!normalized.length) {
    return res.status(200).json({ imported: false, duplicateOnly: true, duplicateCount: duplicateCount, episodeCount: 0 });
  }
  const connected = await pool.query('SELECT id FROM google_drive_credentials WHERE id = 1');
  if (!connected.rowCount) return res.status(409).json({ error: 'Conecte o Google Drive antes de importar os episódios.' });
  const jobId = crypto.randomUUID();
  const client = await pool.connect();
  let series;
  let newEpisodes = [];
  try {
    await client.query('BEGIN');
    const seriesResult = await client.query(
      `INSERT INTO catalog_series (title, synopsis, cover_url) VALUES ($1, $2, $3) ON CONFLICT (title) DO UPDATE SET synopsis = EXCLUDED.synopsis, cover_url = CASE WHEN LENGTH(EXCLUDED.cover_url) > 0 THEN EXCLUDED.cover_url ELSE catalog_series.cover_url END RETURNING id, title`,
      [title, synopsis, coverUrl]
    );
    const seriesId = seriesResult.rows[0].id;
    const existing = await client.query(
      "SELECT video_url FROM catalog_episodes WHERE split_part(video_url, '#', 1) = ANY($1::text[])",
      [normalized.map(e => e.videoUrl)]
    );
    const existingKeys = new Set(existing.rows.map(row => {
      try { const parsed = new URL(row.video_url); parsed.hash = ''; return parsed.toString(); }
      catch (_) { return row.video_url; }
    }));
    newEpisodes = normalized.filter(episode => {
      if (existingKeys.has(episode.urlKey)) { duplicateCount++; return false; }
      return true;
    });
    if (!newEpisodes.length) {
      await client.query('COMMIT');
      return res.status(200).json({
        imported: false, duplicateOnly: true, duplicateCount: duplicateCount,
        episodeCount: 0, series: { id: String(seriesId), title: seriesResult.rows[0].title }
      });
    }
    for (const episode of newEpisodes) {
      await client.query(
        "INSERT INTO catalog_episodes (series_id, episode_number, title, video_url, drive_upload_status, drive_upload_error, drive_upload_job_id) VALUES ($1, $2, $3, $4, 'queued', '', $5) ON CONFLICT (series_id, episode_number) DO UPDATE SET title = EXCLUDED.title, video_url = EXCLUDED.video_url, drive_file_id = NULL, drive_web_view_link = NULL, drive_upload_status = 'queued', drive_upload_error = '', drive_upload_job_id = EXCLUDED.drive_upload_job_id",
        [seriesId, episode.number, episode.title, episode.videoUrl, jobId]
      );
    }
    await client.query(
      "INSERT INTO catalog_drive_upload_jobs (id, series_id, status, total_episodes) VALUES ($1, $2, 'queued', $3)",
      [jobId, seriesId, newEpisodes.length]
    );
    await client.query('COMMIT');
    series = { id: String(seriesId), title: seriesResult.rows[0].title };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Erro ao iniciar importação para o Drive:', error.message);
    return res.status(500).json({ error: 'Não foi possível iniciar a importação.' });
  } finally {
    client.release();
  }
  res.status(202).json({
    imported: true, jobId: jobId, series: series,
    episodeCount: newEpisodes.length, duplicateCount: duplicateCount,
    uploadStatus: 'queued'
  });
  setImmediate(() => processDriveUploadJob(jobId));
});

app.get('/admin/catalog/import-jobs', authRequired, adminRequired, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT j.id AS "jobId", j.status, j.total_episodes AS total,
        COUNT(e.id) FILTER (WHERE e.drive_upload_status = 'uploaded')::int AS uploaded,
        COUNT(e.id) FILTER (WHERE e.drive_upload_status = 'failed')::int AS failed,
        COUNT(e.id) FILTER (WHERE e.drive_upload_status IN ('queued', 'uploading'))::int AS pending,
        s.title
       FROM catalog_drive_upload_jobs j
       JOIN catalog_series s ON s.id = j.series_id
       LEFT JOIN catalog_episodes e ON e.drive_upload_job_id = j.id
       WHERE j.status IN ('failed', 'completed_with_errors', 'queued', 'running')
       GROUP BY j.id, s.title
       ORDER BY j.updated_at DESC
       LIMIT 15`
    );
    return res.json({ jobs: result.rows });
  } catch (error) {
    console.error('Erro ao listar importações do Drive:', error.message);
    return res.status(500).json({ error: 'Não foi possível listar os envios ao Drive.' });
  }
});

app.get('/admin/catalog/import-jobs/:jobId', authRequired, adminRequired, async (req, res) => {
  const jobId = String(req.params.jobId || '');
  if (!/^[0-9a-f-]{36}$/i.test(jobId)) return res.status(400).json({ error: 'Importação inválida.' });
  try {
    const result = await pool.query(
      'SELECT j.id, j.status, j.total_episodes, j.completed_episodes, j.failed_episodes, s.title FROM catalog_drive_upload_jobs j JOIN catalog_series s ON s.id = j.series_id WHERE j.id = $1',
      [jobId]
    );
    if (!result.rowCount) return res.status(404).json({ error: 'Importação não encontrada.' });
    const row = result.rows[0];
    return res.json({
      jobId: row.id, title: row.title, status: row.status,
      total: row.total_episodes, uploaded: row.completed_episodes,
      failed: row.failed_episodes,
      pending: Math.max(0, row.total_episodes - row.completed_episodes - row.failed_episodes)
    });
  } catch (error) {
    console.error('Erro ao consultar progresso da importação:', error.message);
    return res.status(500).json({ error: 'Não foi possível consultar o progresso.' });
  }
});

app.post('/admin/catalog/import-jobs/:jobId/retry', authRequired, adminRequired, async (req, res) => {
  const jobId = String(req.params.jobId || '');
  if (!/^[0-9a-f-]{36}$/i.test(jobId)) return res.status(400).json({ error: 'Importação inválida.' });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const jobResult = await client.query(
      'SELECT id, status FROM catalog_drive_upload_jobs WHERE id = $1 FOR UPDATE',
      [jobId]
    );
    if (!jobResult.rowCount) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Importação não encontrada.' });
    }
    if (jobResult.rows[0].status === 'running') {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'Esta importação já está em andamento.' });
    }
    const uploadedResult = await client.query(
      "SELECT COUNT(*)::int AS count FROM catalog_episodes WHERE drive_upload_job_id = $1 AND drive_upload_status = 'uploaded'",
      [jobId]
    );
    const uploaded = uploadedResult.rows[0].count;
    await client.query(
      "UPDATE catalog_episodes SET drive_upload_status = 'queued', drive_upload_error = '' WHERE drive_upload_job_id = $1 AND drive_upload_status IN ('failed', 'uploading')",
      [jobId]
    );
    const pendingResult = await client.query(
      "SELECT COUNT(*)::int AS count FROM catalog_episodes WHERE drive_upload_job_id = $1 AND drive_upload_status = 'queued'",
      [jobId]
    );
    const pending = pendingResult.rows[0].count;
    if (!pending) {
      await client.query(
        "UPDATE catalog_drive_upload_jobs SET status = 'completed', completed_episodes = $2, failed_episodes = 0, updated_at = NOW() WHERE id = $1",
        [jobId, uploaded]
      );
      await client.query('COMMIT');
      return res.json({ retried: false, uploaded, pending: 0, message: 'Todos os episódios já estão enviados.' });
    }
    await client.query(
      "UPDATE catalog_drive_upload_jobs SET status = 'queued', completed_episodes = $2, failed_episodes = 0, updated_at = NOW() WHERE id = $1",
      [jobId, uploaded]
    );
    await client.query('COMMIT');
    res.status(202).json({ retried: true, uploaded, pending });
    setImmediate(() => processDriveUploadJob(jobId));
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Erro ao retomar envio ao Google Drive:', error.message);
    return res.status(500).json({ error: 'Não foi possível retomar o envio.' });
  } finally {
    client.release();
  }
});

app.post('/admin/catalog/series/:seriesId/episodes', authRequired, adminRequired, async (req, res) => {
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

app.delete('/admin/catalog/series/:seriesId', authRequired, adminRequired, async (req, res) => {
  const seriesId = Number(req.params.seriesId);
  if (!Number.isSafeInteger(seriesId) || seriesId < 1) {
    return res.status(400).json({ error: 'Série inválida.' });
  }
  try {
    const result = await pool.query(
      'DELETE FROM catalog_series WHERE id = $1 RETURNING id, title',
      [seriesId]
    );
    if (!result.rowCount) return res.status(404).json({ error: 'Publicação não encontrada.' });
    return res.json({ deleted: true, series: { id: String(result.rows[0].id), title: result.rows[0].title } });
  } catch (error) {
    console.error('Erro ao excluir publicação:', error.message);
    return res.status(500).json({ error: 'Não foi possível excluir a publicação.' });
  }
});

app.get('/admin/users', authRequired, adminRequired, async (req, res) => {
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
  .then(async () => {
    await pool.query("UPDATE catalog_drive_upload_jobs SET status = 'queued' WHERE status = 'running'");
    await pool.query("UPDATE catalog_episodes SET drive_upload_status = 'queued' WHERE drive_upload_status = 'uploading'");
    await pool.query("UPDATE catalog_drive_recovery_jobs SET status = 'queued' WHERE status = 'running'");
    await pool.query("UPDATE catalog_episodes SET drive_recovery_status = 'queued' WHERE drive_recovery_status = 'recovering'");
    app.listen(port, '0.0.0.0', () => console.log(`NovelPlay API ativa na porta ${port}`));
    const pendingJobs = await pool.query("SELECT id FROM catalog_drive_upload_jobs WHERE status = 'queued' ORDER BY created_at");
    for (const job of pendingJobs.rows) setImmediate(() => processDriveUploadJob(job.id));
    const pendingRecoveryJobs = await pool.query("SELECT id FROM catalog_drive_recovery_jobs WHERE status = 'queued' ORDER BY created_at");
    for (const job of pendingRecoveryJobs.rows) setImmediate(() => processDriveRecoveryJob(job.id));
  })
  .catch(error => {
    console.error('Falha ao inicializar banco:', error.message);
    process.exit(1);
  });