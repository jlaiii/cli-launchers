// claude-deepseek-proxy.js
// Bridges Claude Code v2.1.153+ with DeepSeek API.
// DeepSeek returns malformed thinking blocks in SSE stream - this proxy
// sanitizes them and keeps SSE protocol intact.

const http = require('http');
const https = require('https');
const TARGET = 'api.deepseek.com';
const PORT = 9876;

function sanitizeSSE(line) {
  if (!line.startsWith('data: ')) return line;
  try {
    let d = JSON.parse(line.slice(6));
    if (d.content_block && d.content_block.type === 'thinking') {
      d.content_block.thinking = '';
      d.content_block.signature = '';
      return 'data: ' + JSON.stringify(d) + '\n';
    }
    if (d.delta && d.delta.type === 'thinking_delta') {
      d.delta.thinking = '';
      return 'data: ' + JSON.stringify(d) + '\n';
    }
  } catch(e) {}
  return line;
}

http.createServer((req, res) => {
  if (req.method === 'GET') { res.writeHead(200); return res.end('ok'); }

  let body = [];
  req.on('data', c => body.push(c));
  req.on('end', () => {
    let raw = Buffer.concat(body).toString();
    try {
      let j = JSON.parse(raw);
      if (j.thinking) delete j.thinking;
      if (j.messages) {
        for (let m of j.messages) {
          if (m.content && Array.isArray(m.content)) {
            m.content = m.content.map(b =>
              b.type === 'thinking' ? { type: 'thinking', thinking: '', signature: b.signature || '' } : b
            );
          }
        }
      }
      raw = JSON.stringify(j);
    } catch (e) {}

    let headers = { ...req.headers, host: TARGET, 'content-length': Buffer.byteLength(raw) };
    delete headers['accept-encoding'];

    let preq = https.request({ hostname: TARGET, port: 443, path: req.url, method: req.method, headers }, pres => {
      let ct = (pres.headers['content-type'] || '');
      res.writeHead(pres.statusCode, pres.headers);

      if (ct.includes('text/event-stream')) {
        let buf = '';
        pres.on('data', c => {
          buf += c.toString();
          let parts = buf.split('\n');
          buf = parts.pop() || '';
          for (let line of parts) res.write(sanitizeSSE(line + '\n'));
        });
        pres.on('end', () => { if (buf) res.write(sanitizeSSE(buf)); res.end(); });
      } else {
        pres.pipe(res);
      }
    });

    preq.on('error', e => { if (!res.headersSent) { try { res.writeHead(502); } catch(_){} } res.end(e.message); });
    preq.write(raw);
    preq.end();
  });
}).listen(PORT, () => console.log('Claude DeepSeek proxy on port ' + PORT));
