'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const { EventEmitter, once } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');
const { AppServerGateway, gatewayEnabled, readProjectedSecret, readRuntimeCredentials,
  websocketAccept } = require('./app-server-gateway.js');
const { OptionalGatewayService, gatewayLaunch, parseDockerEnvironment, prepareGatewayRuntime } = require('./supervisor.js');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cg-'));
const key = path.join(root, 'key.pem');
const cert = path.join(root, 'cert.pem');
childProcess.execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
  '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
  '-keyout', key, '-out', cert], { stdio: 'ignore' });
const credentials = { token: crypto.randomBytes(32).toString('base64url'), key: fs.readFileSync(key),
  cert: fs.readFileSync(cert) };
let fixtureNumber = 0;
test.after(() => fs.rmSync(root, { recursive: true, force: true }));

async function waitFor(predicate, timeout = 3000) {
  const until = Date.now() + timeout;
  while (!await predicate()) {
    if (Date.now() > until) throw new Error('test deadline exceeded');
    await delay(10);
  }
}

async function fixture(t, { upstream = true, bootstrap = async () => {}, handshakeTimeoutMs = 100 } = {}) {
  const directory = path.join(root, String(fixtureNumber++));
  fs.mkdirSync(directory, { mode: 0o700 });
  const realSocket = path.join(directory, 'real.sock');
  const socketPath = path.join(directory, 'control.sock');
  fs.symlinkSync(realSocket, socketPath);
  const peers = new Set();
  const requests = [];
  let server;
  async function openUpstream(handler) {
    server = http.createServer((_request, response) => response.writeHead(404).end());
    server.on('upgrade', (request, socket, head) => {
      peers.add(socket);
      socket.on('error', () => {});
      socket.once('close', () => peers.delete(socket));
      requests.push(request);
      if (handler) { handler(request, socket, head); return; }
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ${websocketAccept(request.headers['sec-websocket-key'])}\r\n\r\n`);
      if (head.length) socket.write(head);
      socket.pipe(socket);
    });
    await new Promise((resolve) => server.listen(realSocket, resolve));
    fs.chmodSync(realSocket, 0o600);
  }
  async function closeUpstream() {
    if (!server) return;
    for (const socket of peers) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    server = null;
  }
  if (upstream) await openUpstream();
  const gateway = new AppServerGateway({ credentials, socketPath, uid: process.getuid(),
    host: '127.0.0.1', port: 0, handshakeTimeoutMs, retryMaxMs: 20, bootstrap });
  await gateway.start();
  const options = { hostname: '127.0.0.1', port: gateway.server.address().port, ca: credentials.cert,
    servername: 'localhost', agent: false };
  t.after(async () => { await gateway.stop(); await closeUpstream(); });
  const get = (url) => new Promise((resolve, reject) => {
    https.get({ ...options, path: url }, (response) => {
      response.resume();
      response.once('end', () => resolve(response.statusCode));
    }).once('error', reject);
  });
  const connect = (extraHeaders = {}, url = '/') => new Promise((resolve, reject) => {
    const request = https.request({ ...options, method: 'GET', path: url, headers: {
      Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'),
      Authorization: `Bearer ${credentials.token}`, ...extraHeaders,
    } });
    request.once('upgrade', (_response, socket, head) => { socket.on('error', () => {}); resolve({ status: 101, socket, head }); });
    request.once('response', (response) => { response.resume(); resolve({ status: response.statusCode }); });
    request.once('error', reject);
    request.end();
  });
  return { gateway, socketPath, realSocket, directory, get, connect, requests, peers, openUpstream, closeUpstream };
}

test('opt-in is limited to the requested ordinal and never implicitly starts other replicas', () => {
  assert.equal(gatewayEnabled({}), false);
  assert.equal(gatewayEnabled({ CODEX_APP_SERVER_ENABLED: '0' }), false);
  assert.equal(gatewayEnabled({ CODEX_APP_SERVER_ENABLED: '1' }), true);
  const env = { CODEX_APP_SERVER_ENABLED: '1', CODEX_APP_SERVER_ORDINAL: '2' };
  assert.equal(gatewayEnabled(env, 'codex-devbox-2'), true);
  assert.equal(gatewayEnabled(env, 'codex-devbox-0'), false);
  assert.throws(() => gatewayEnabled({ ...env, CODEX_APP_SERVER_ORDINAL: '../../2' }));
});

test('authenticated TLS WebSocket relays bytes unchanged and strips credentials upstream', async (t) => {
  const f = await fixture(t);
  assert.equal(await f.get('/livez'), 200);
  assert.equal(await f.get('/readyz'), 200);
  const { status, socket } = await f.connect();
  assert.equal(status, 101);
  const payload = crypto.randomBytes(512 * 1024);
  const chunks = [];
  let received = 0;
  const echoed = new Promise((resolve) => socket.on('data', (chunk) => {
    chunks.push(chunk); received += chunk.length;
    if (received === payload.length) resolve(Buffer.concat(chunks));
  }));
  socket.write(payload);
  assert.deepEqual(await echoed, payload);
  assert.ok(f.requests.length >= 2);
  for (const request of f.requests) {
    assert.equal(request.headers.authorization, undefined);
    assert.equal(request.headers.origin, undefined);
  }
  socket.destroy();
});

test('missing/wrong/duplicate auth, every Origin, and unsupported paths fail before upstream', async (t) => {
  const f = await fixture(t);
  await f.gateway.probe();
  const before = f.requests.length;
  const cases = [
    [{ Authorization: '' }, '/', 401],
    [{ Authorization: `Bearer ${'x'.repeat(32)}` }, '/', 401],
    [{ Authorization: [`Bearer ${credentials.token}`, `Bearer ${credentials.token}`] }, '/', 401],
    [{ Origin: 'https://localhost' }, '/', 403],
    [{ Origin: '' }, '/', 403],
    [{}, '/?token=ignored', 400],
    [{ 'Sec-WebSocket-Protocol': 'jsonrpc' }, '/', 400],
    [{ 'Sec-WebSocket-Key': 'invalid' }, '/', 400],
  ];
  for (const [headers, url, expected] of cases) assert.equal((await f.connect(headers, url)).status, expected);
  assert.equal(f.requests.length, before);
  assert.equal(await f.get('/'), 404);
});

test('readiness verifies a real upgrade and bootstrap recovery preserves a live gateway', async (t) => {
  let bootstrapCalls = 0;
  const f = await fixture(t, { upstream: false, bootstrap: async () => { bootstrapCalls++; } });
  assert.equal(await f.get('/livez'), 200);
  assert.equal(await f.get('/readyz'), 503);
  assert.equal((await f.connect()).status, 503);
  await waitFor(() => bootstrapCalls > 0);
  await f.openUpstream();
  assert.equal(await f.get('/readyz'), 200);
  const first = await f.connect();
  const disconnected = once(first.socket, 'close');
  await f.closeUpstream();
  await disconnected;
  assert.equal(await f.get('/readyz'), 503);
  assert.equal(await f.get('/livez'), 200);
  await f.openUpstream();
  assert.equal(await f.get('/readyz'), 200);
  const second = await f.connect();
  assert.equal(second.status, 101);
  second.socket.destroy();
});

test('handshake deadlines and invalid accept responses fail closed without breaking health', async (t) => {
  const f = await fixture(t, { upstream: false });
  await f.openUpstream(() => {});
  assert.equal(await f.get('/readyz'), 503);
  assert.equal((await f.connect()).status, 503);
  assert.equal(await f.get('/livez'), 200);
  await f.closeUpstream();
  await f.openUpstream((_request, socket) => socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: wrong\r\n\r\n'));
  assert.equal(await f.get('/readyz'), 503);
});

test('unsafe socket endpoints are rejected while official private-directory symlinks work', async (t) => {
  const f = await fixture(t);
  assert.equal(await f.get('/readyz'), 200);
  fs.chmodSync(f.realSocket, 0o666);
  assert.equal(await f.get('/readyz'), 503);
  fs.chmodSync(f.realSocket, 0o600);
  fs.chmodSync(f.directory, 0o777);
  assert.equal(await f.get('/readyz'), 503);
  fs.chmodSync(f.directory, 0o700);
  assert.equal(await f.get('/readyz'), 200);
});

test('shutdown closes active relays and cancels further daemon bootstrap', async (t) => {
  const f = await fixture(t);
  const { socket } = await f.connect();
  const closed = once(socket, 'close');
  await f.gateway.stop();
  await closed;
  assert.equal(f.gateway.connections.size, 0);
  assert.equal(f.gateway.ready, false);
});

test('projected credentials stay inside the mount and runtime copies use private metadata', () => {
  const directory = path.join(root, String(fixtureNumber++));
  fs.mkdirSync(directory, { mode: 0o700 });
  const source = path.join(directory, 'source');
  const generation = path.join(source, '..generation');
  fs.mkdirSync(source); fs.mkdirSync(generation);
  const fields = { token: credentials.token, 'tls.crt': credentials.cert, 'tls.key': credentials.key };
  for (const [name, value] of Object.entries(fields)) {
    fs.writeFileSync(path.join(generation, name), value, { mode: 0o400 });
    fs.symlinkSync(`..generation/${name}`, path.join(source, name));
  }
  const env = { CODEX_APP_SERVER_TOKEN_FILE: path.join(source, 'token'),
    CODEX_APP_SERVER_TLS_CERT_FILE: path.join(source, 'tls.crt'),
    CODEX_APP_SERVER_TLS_KEY_FILE: path.join(source, 'tls.key') };
  const runtime = path.join(directory, 'runtime');
  const options = { directory: runtime, sourceDirectory: source, sourceUid: process.getuid(),
    parentUid: process.getuid(), uid: process.getuid(), gid: process.getgid() };
  const original = prepareGatewayRuntime(env, options);
  assert.equal(readRuntimeCredentials(runtime, process.getuid()).token, credentials.token);
  assert.equal(fs.statSync(path.join(runtime, 'token')).mode & 0o777, 0o600);
  fs.chmodSync(path.join(generation, 'token'), 0o600);
  fs.writeFileSync(path.join(generation, 'token'), crypto.randomBytes(32).toString('hex'));
  fs.chmodSync(path.join(generation, 'token'), 0o400);
  assert.notEqual(prepareGatewayRuntime(env, options), original);
  fs.chmodSync(path.join(generation, 'token'), 0o444);
  assert.throws(() => prepareGatewayRuntime(env, options));
  fs.unlinkSync(path.join(source, 'token'));
  fs.symlinkSync(key, path.join(source, 'token'));
  assert.throws(() => readProjectedSecret(path.join(source, 'token'), { root: source, uid: process.getuid() }));
});

function fakeChild() {
  const child = new EventEmitter();
  child.exitCode = null; child.signalCode = null;
  child.kill = (signal) => {
    if (child.signalCode) return;
    child.signalCode = signal;
    queueMicrotask(() => child.emit('close', null, signal));
  };
  return child;
}

test('optional service retries independently, replaces rotated credentials, and stops cleanly', async () => {
  let calls = 0;
  let signature = 'first';
  const children = [];
  const service = new OptionalGatewayService({ retryMs: 5, maxRetryMs: 10, credentialPollMs: 5,
    listenTimeoutMs: 100, log: () => {}, currentSignature: () => signature,
    launch: () => {
      if (++calls === 1) throw new Error('missing secret');
      const child = fakeChild();
      child.gatewaySignature = signature;
      children.push(child);
      queueMicrotask(() => child.emit('message', { type: 'listening' }));
      return child;
    } });
  service.start();
  await waitFor(() => children.length === 1);
  signature = 'second';
  await waitFor(() => children.length === 2);
  assert.equal(children[0].signalCode, 'SIGTERM');
  await service.stop();
  const stopped = calls;
  await delay(30);
  assert.equal(calls, stopped);
  assert.equal(children[1].signalCode, 'SIGTERM');
});

test('optional gateway launch clears ambient configuration and uses the trusted codex identity', () => {
  const directive = 'SetEnv DOCKER_HOST=unix:///run/codex-remote-devbox/docker-bridge/docker.sock TESTCONTAINERS_HOST_OVERRIDE=docker-host.example TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock';
  const spec = gatewayLaunch(directive);
  assert.equal(spec.command, '/usr/bin/setpriv');
  assert.ok(spec.args.includes('--reuid=1000'));
  assert.ok(spec.args.includes('--clear-groups'));
  assert.equal(spec.args.includes('--no-new-privs'), false);
  assert.equal(spec.options.env.TESTCONTAINERS_HOST_OVERRIDE, 'docker-host.example');
  assert.equal(spec.options.env.DOCKER_HOST, 'unix:///run/codex-remote-devbox/docker-bridge/docker.sock');
  assert.equal(spec.options.env.DOCKER_CONTEXT, undefined);
  for (const config of ['', `${directive}\n${directive}`, directive.replace('docker-host.example', '$(evil)'),
    `${directive} EXTRA=evil`, directive.replace('unix:///run/codex-remote-devbox/docker-bridge/docker.sock', 'tcp://evil:2375')]) {
    assert.throws(() => parseDockerEnvironment(config));
  }
  assert.equal(spec.options.env.HOME, '/home/codex');
  assert.equal(spec.options.env.CODEX_HOME, undefined);
  assert.equal(spec.options.env.CODEX_APP_SERVER_TOKEN_FILE, undefined);
  assert.deepEqual(spec.options.stdio, ['ignore', 'ignore', 'inherit', 'ipc']);
});


test('credential revocation closes the gateway and prevents retries from exposing stale secrets', async () => {
  let revoked = false;
  let launches = 0;
  const children = [];
  const service = new OptionalGatewayService({ retryMs: 5, maxRetryMs: 10, credentialPollMs: 5,
    listenTimeoutMs: 100, log: () => {},
    currentSignature: () => { if (revoked) throw new Error('source removed'); return 'present'; },
    launch: () => {
      launches++;
      if (revoked) throw new Error('source removed');
      const child = fakeChild();
      child.gatewaySignature = 'present';
      children.push(child);
      queueMicrotask(() => child.emit('message', { type: 'listening' }));
      return child;
    } });
  service.start();
  await waitFor(() => children.length === 1);
  revoked = true;
  await waitFor(() => children[0].signalCode === 'SIGTERM' && launches > 1);
  assert.equal(children.length, 1);
  revoked = false;
  await waitFor(() => children.length === 2);
  await service.stop();
});

test('an optional worker that never opens its listener is reaped and retried', async () => {
  const children = [];
  const service = new OptionalGatewayService({ retryMs: 5, maxRetryMs: 10,
    listenTimeoutMs: 10, log: () => {}, launch: () => {
      const child = fakeChild(); children.push(child); return child;
    } });
  service.start();
  await waitFor(() => children.length >= 2);
  assert.equal(children[0].signalCode, 'SIGKILL');
  await service.stop();
});
