// Independent HTTPS peer. Certificates and credentials are ephemeral fixtures;
// only the qualification process uses Node/OpenSSL, never the native consumer.
import assert from 'node:assert/strict';
import {createServer} from 'node:https';
import {spawn} from 'node:child_process';
import {mkdtemp, writeFile, rm} from 'node:fs/promises';
import {X509Certificate} from 'node:crypto';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {once} from 'node:events';
import {certificates} from '../support/tls.mjs';

const directory = await mkdtemp(join(tmpdir(), 'native HTTPS ü '));
const binary = resolve(process.argv[2]);
let server;
const sockets = new Set(), calls = [];
try {
  const tls = await certificates(directory, {invalidServerCertificates: true});
  assert.equal(new X509Certificate(tls.B.cert).checkIP('127.0.0.1'), undefined);
  assert(Date.parse(new X509Certificate(tls.C.cert).validTo) < Date.now());
  const root = join(directory, 'root.der');
  await writeFile(root, new X509Certificate(tls.ca).raw);
  server = createServer(tls.A, async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    calls.push({url: request.url, method: request.method, headers: request.headers, body: Buffer.concat(chunks).toString()});
    response.setHeader('x-request-id', 'fixture-response');
    if (request.url === '/held') return;
    if (request.url === '/truncated' || request.url === '/truncated-chunked') {
      // Write the complete malformed HTTP envelope directly: ending the TLS
      // socket after ServerResponse.write can discard its queued HTTP header.
      const framing = request.url === '/truncated' ? 'Content-Length: 100\r\n\r\npartial' : 'Transfer-Encoding: chunked\r\n\r\n7\r\npartial\r\n';
      return response.socket.end(`HTTP/1.1 200 OK\r\nConnection: close\r\n${framing}`);
    }
    if (request.url === '/large') return response.end('x'.repeat(1025));
    if (request.url === '/encoded') { response.setHeader('content-encoding', 'gzip'); return response.end('unsupported'); }
    if (request.url === '/redirect') { response.statusCode = 307; response.setHeader('location', '/forbidden'); return response.end('redirect'); }
    if (request.url === '/failed') response.statusCode = 429;
    response.end('{"output":"雪","integer":9007199254740993}');
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  server.on('tlsClientError', () => {});
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const endpoint = `https://127.0.0.1:${server.address().port}`;
  async function run(path, {timeout = 2000, trust = root, url = endpoint} = {}) {
    const child = spawn(binary, ['https', `${url}${path}`, trust, String(timeout), '{"input":"fixture"}'], {cwd: directory, env: {PATH: '/nonexistent'}, stdio: ['ignore', 'pipe', 'pipe']});
    let stdout = '', stderr = '';
    child.stdout.on('data', bytes => { stdout += bytes; });
    child.stderr.on('data', bytes => { stderr += bytes; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
    try {
      const [code, signal] = await once(child, 'close');
      assert.equal(signal, null, stderr);
      assert.equal(code, 0, stderr);
      return stdout;
    } finally { clearTimeout(timer); }
  }
  assert.equal(await run('/ok'), 'captured 200 fixture-response\n{"output":"雪","integer":9007199254740993}');
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].headers.authorization, 'Bearer qualification-only');
  assert.equal(calls[0].headers['accept-encoding'], 'identity');
  assert.equal(calls[0].body, '{"input":"fixture"}');
  assert.match(await run('/failed'), /^captured 429 fixture-response\n/);
  assert.equal(await run('/redirect'), 'captured 307 fixture-response\nredirect');
  assert.equal(calls.filter(call => call.url === '/forbidden').length, 0);
  assert.equal(await run('/large'), 'unknown ResponseCapacity\n');
  assert.equal(await run('/encoded'), 'captured 200 fixture-response\nunsupported');
  // Allow the ordinary TLS/request budget before testing the held response.
  // The recorded request below establishes that this timeout was post-send.
  assert.equal(await run('/held'), 'unknown Timeout\n');
  assert.equal(calls.filter(call => call.url === '/held').length, 1, 'no timeout retry');
  for (const [path, failure] of [['/truncated', 'TruncatedResponse'], ['/truncated-chunked', 'HttpChunkTruncated']]) {
    assert.equal(await run(path), `unknown ${failure}\n`, 'truncated response cannot become a complete capture or wait for the deadline');
    assert.equal(calls.filter(call => call.url === path).length, 1, 'no retry after truncated acquisition');
  }
  const wrong = join(directory, 'wrong.der');
  await writeFile(wrong, new X509Certificate(tls.B.cert).raw);
  const before = calls.length;
  assert.match(await run('/untrusted', {trust: wrong}), /^not-sent /);
  assert.equal(calls.length, before, 'untrusted TLS prevents dispatch');
  assert.equal(await run('/plaintext', {url: endpoint.replace('https:', 'http:')}), 'not-sent InvalidConfiguration\n');
  assert.equal(calls.length, before);
  for (const [name, certificate] of [['wrong-host', tls.B], ['expired', tls.C]]) {
    server.setSecureContext(certificate);
    assert.match(await run(`/${name}`), /^not-sent /);
    assert.equal(calls.length, before, `${name} TLS prevents dispatch`);
  }
  server.setSecureContext(tls.A);
  assert.match(await run('/restored'), /^captured 200 /, 'valid TLS remains usable after rejection');
  console.log(JSON.stringify({native_https: true, calls: calls.length, redirects: 0, retries: 0, exact_body: true, tls_rejection: true, bounded_response: true, deadline: true}));
} finally {
  for (const socket of sockets) socket.destroy();
  if (server?.listening) await new Promise(resolve => server.close(resolve));
  await rm(directory, {recursive: true, force: true});
}
