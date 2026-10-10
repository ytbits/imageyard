#!/usr/local/bin/node
'use strict';

// Trusted-network transport only: no authentication or TLS. JSON-RPC and
// WebSocket frames pass through unchanged to this Devbox's managed daemon.
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const net = require('node:net');
const path = require('node:path');

const SOCKET_PATH = '/home/codex/.codex/app-server-control/app-server-control.sock';
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const HANDSHAKE_TIMEOUT_MS = 3000;
const BOOTSTRAP_TIMEOUT_MS = 15000;
const RETRY_MAX_MS = 30000;
const MAX_CONNECTIONS = 128;

function gatewayEnabled(environment = process.env, hostname = os.hostname()) {
  if (environment.CODEX_APP_SERVER_ENABLED !== '1') return false;
  const ordinal = environment.CODEX_APP_SERVER_ORDINAL;
  if (ordinal === undefined || ordinal === '') return true;
  if (!/^(0|[1-9][0-9]*)$/.test(ordinal)) throw new Error('invalid app-server ordinal');
  return hostname === `codex-devbox-${ordinal}`;
}

function hasHeader(request, name) {
  return request.rawHeaders.some((value, index) => index % 2 === 0 && value.toLowerCase() === name);
}
function headerCount(request, name) {
  return request.rawHeaders.filter((value, index) => index % 2 === 0 && value.toLowerCase() === name).length;
}
function websocketAccept(key) { return crypto.createHash('sha1').update(key + GUID).digest('base64'); }

class AppServerGateway {
  constructor({ socketPath = SOCKET_PATH, uid = 1000, host = '0.0.0.0', port = 8787,
    handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS, retryMaxMs = RETRY_MAX_MS,
    bootstrap = startDaemon, onReady = () => {}, onFatal = () => {}, log = () => {} }) {
    Object.assign(this, { socketPath, uid, host, port, handshakeTimeoutMs, retryMaxMs, bootstrap, onReady, onFatal, log });
    this.connections = new Set();
    this.pending = new Set();
    this.closing = false;
    this.ready = false;
    this.retryMs = 1000;
    this.server = http.createServer({ maxHeaderSize: 8192, headersTimeout: 5000, requestTimeout: 5000, connectionsCheckingInterval: 1000 }, (request, response) => {
      request.resume();
      response.setHeader('Cache-Control', 'no-store');
      if (request.method !== 'GET') { response.writeHead(405).end(); return; }
      if (request.url === '/livez') { response.writeHead(this.closing ? 503 : 200).end(); return; }
      if (request.url === '/readyz') {
        this.probe().then((ready) => response.writeHead(ready ? 200 : 503).end());
        return;
      }
      response.writeHead(404).end();
    });
    this.server.on('upgrade', (request, socket, head) => this.upgrade(request, socket, head));
    this.server.on('connection', (socket) => {
      this.connections.add(socket);
      socket.on('error', () => {});
      socket.once('close', () => this.connections.delete(socket));
    });
    this.server.on('clientError', (_error, socket) => socket.destroy());
    this.server.maxConnections = MAX_CONNECTIONS;
  }

  validSocket() {
    const link = fs.lstatSync(this.socketPath);
    const parent = fs.lstatSync(path.dirname(this.socketPath));
    const resolved = fs.realpathSync(this.socketPath);
    const targetParent = fs.lstatSync(path.dirname(resolved));
    const stat = fs.lstatSync(resolved);
    // The official daemon advertises a Home symlink into its private /tmp
    // directory. Verify both directories and the actual endpoint deliberately.
    if (link.uid !== this.uid || !parent.isDirectory() || parent.isSymbolicLink() ||
        parent.uid !== this.uid || (parent.mode & 0o022) !== 0 ||
        !targetParent.isDirectory() || targetParent.isSymbolicLink() ||
        targetParent.uid !== this.uid || (targetParent.mode & 0o022) !== 0 ||
        !stat.isSocket() || stat.uid !== this.uid || (stat.mode & 0o777) !== 0o600) {
      throw new Error('unsafe app-server socket');
    }
    return resolved;
  }

  upstream(key) {
    return new Promise((resolve, reject) => {
      let resolved;
      try { resolved = this.validSocket(); } catch { reject(new Error('app-server unavailable')); return; }
      const request = http.request({ socketPath: resolved, method: 'GET', path: '/', agent: false,
        maxHeaderSize: 8192,
        headers: { Host: 'localhost', Connection: 'Upgrade', Upgrade: 'websocket',
          'Sec-WebSocket-Key': key, 'Sec-WebSocket-Version': '13' } });
      this.pending.add(request);
      let done = false;
      const finish = (error, value) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        this.pending.delete(request);
        if (error) { request.destroy(); reject(new Error('app-server unavailable')); }
        else resolve(value);
      };
      const timer = setTimeout(() => finish(new Error('handshake timeout')), this.handshakeTimeoutMs);
      request.once('error', () => finish(new Error('connection failed')));
      request.once('response', (response) => { response.destroy(); finish(new Error('upgrade rejected')); });
      request.once('upgrade', (response, socket, head) => {
        socket.on('error', () => {});
        if (this.closing || response.statusCode !== 101 ||
            response.headers.upgrade?.toLowerCase() !== 'websocket' ||
            !response.headers.connection?.toLowerCase().split(/\s*,\s*/).includes('upgrade') ||
            response.headers['sec-websocket-accept'] !== websocketAccept(key) ||
            response.headers['sec-websocket-extensions'] || response.headers['sec-websocket-protocol']) {
          socket.destroy(); finish(new Error('invalid upgrade')); return;
        }
        finish(null, { socket, head });
      });
      request.end();
    });
  }

  async probe() {
    if (this.closing) return false;
    if (!this.probing) {
      this.probing = this.upstream(crypto.randomBytes(16).toString('base64'))
        .then(({ socket }) => { socket.destroy(); return true; }, () => false)
        .then((ready) => { ready = ready && !this.closing; this.setReady(ready); return ready; })
        .finally(() => { this.probing = null; });
    }
    return this.probing;
  }

  setReady(ready) {
    if (this.ready === ready) return;
    this.ready = ready;
    this.onReady(ready);
  }

  async upgrade(request, socket, head) {
    const reject = (status) => {
      socket.setTimeout(this.handshakeTimeoutMs, () => socket.destroy());
      if (!socket.destroyed) socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    };
    socket.on('error', () => {});
    if (this.closing) { reject('503 Service Unavailable'); return; }
    const key = request.headers['sec-websocket-key'];
    if (request.method !== 'GET' || request.url !== '/' || request.headers.upgrade?.toLowerCase() !== 'websocket' ||
        request.headers['sec-websocket-version'] !== '13' || typeof key !== 'string' ||
        !/^[A-Za-z0-9+/]{22}==$/.test(key) || headerCount(request, 'sec-websocket-key') !== 1 ||
        hasHeader(request, 'sec-websocket-protocol')) { reject('400 Bad Request'); return; }
    socket.pause();
    let upstream;
    try { upstream = await this.upstream(key); } catch {
      this.setReady(false);
      reject('503 Service Unavailable'); return;
    }
    if (socket.destroyed || this.closing) { upstream.socket.destroy(); return; }
    this.setReady(true);
    this.connections.add(upstream.socket);
    const close = () => {
      socket.destroy();
      upstream.socket.destroy();
      this.connections.delete(upstream.socket);
    };
    socket.once('close', close);
    upstream.socket.once('close', close);
    socket.once('error', close);
    upstream.socket.once('error', close);
    socket.setTimeout(0);
    upstream.socket.setTimeout(0);
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${websocketAccept(key)}\r\n\r\n`);
    if (upstream.head.length) socket.write(upstream.head);
    if (head.length) upstream.socket.write(head);
    socket.pipe(upstream.socket);
    upstream.socket.pipe(socket);
    socket.resume();
  }

  async recover() {
    if (this.closing) return;
    if (await this.probe()) this.retryMs = 1000;
    else {
      try { await this.bootstrap(this.abort.signal); } catch { this.log('app-server bootstrap unavailable'); }
      if (this.closing) return;
      if (await this.probe()) this.retryMs = 1000;
      else this.retryMs = Math.min(this.retryMs * 2, this.retryMaxMs);
    }
    if (!this.closing) this.recoveryTimer = setTimeout(() => void this.recover(), this.ready ? 5000 : this.retryMs);
  }

  async start() {
    this.abort = new AbortController();
    await new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.port, this.host, () => { this.server.off('error', reject); resolve(); });
    });
    this.server.on('error', () => { this.log('gateway listener failed'); void this.stop().then(this.onFatal); });
    void this.recover();
  }

  async stop() {
    if (this.closing) return;
    this.closing = true;
    clearTimeout(this.recoveryTimer);
    this.abort?.abort();
    this.setReady(false);
    for (const request of this.pending) request.destroy();
    for (const socket of this.connections) socket.destroy();
    await new Promise((resolve) => this.server.close(resolve));
  }
}

function dockerEnvironment(environment) {
  const host = environment.TESTCONTAINERS_HOST_OVERRIDE;
  if (environment.DOCKER_HOST !== 'unix:///run/codex-remote-devbox/docker-bridge/docker.sock' ||
      environment.TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE !== '/var/run/docker.sock' ||
      typeof host !== 'string' || host.length > 253 ||
      (!net.isIP(host) && !/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(host))) {
    throw new Error('invalid daemon Docker environment');
  }
  return { DOCKER_HOST: environment.DOCKER_HOST, TESTCONTAINERS_HOST_OVERRIDE: host,
    TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE: environment.TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE };
}

function startDaemon(signal) {
  return new Promise((resolve, reject) => {
    // No shell, no inherited client authentication, no model request. The
    // official daemon command owns the single-instance lock and socket cleanup.
    const child = childProcess.spawn('/usr/local/bin/codex', ['app-server', 'daemon', 'start'], {
      env: { HOME: '/home/codex', USER: 'codex', LOGNAME: 'codex', LANG: 'C.UTF-8',
        PATH: '/usr/local/bin:/usr/bin:/bin', SHELL: '/bin/bash', ...dockerEnvironment(process.env) },
      stdio: 'ignore',
    });
    let finished = false;
    let killTimer;
    const terminate = () => {
      if (finished || killTimer) return;
      child.kill('SIGTERM');
      killTimer = setTimeout(() => child.kill('SIGKILL'), 1000);
    };
    const timer = setTimeout(terminate, BOOTSTRAP_TIMEOUT_MS);
    const finish = (success) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      clearTimeout(killTimer);
      signal?.removeEventListener('abort', terminate);
      if (success && !signal?.aborted) resolve();
      else reject(new Error('daemon bootstrap failed'));
    };
    child.once('error', () => finish(false));
    child.once('close', (code) => finish(code === 0));
    signal?.addEventListener('abort', terminate, { once: true });
    if (signal?.aborted) terminate();
  });
}

async function main() {
  if (process.getuid() !== 1000 || process.getgid() !== 1000 || process.env.HOME !== '/home/codex' ||
      process.env.CODEX_HOME || process.argv.length !== 2) throw new Error('invalid gateway identity');
  const gateway = new AppServerGateway({
    onReady: (ready) => { if (process.connected) process.send({ type: 'ready', ready }); },
    onFatal: () => { process.exitCode = 1; if (process.connected) process.disconnect(); },
    log: (message) => process.stderr.write(`codex-app-server-gateway: ${message}\n`) });
  const stop = () => void gateway.stop().then(() => { if (process.connected) process.disconnect(); });
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  process.on('SIGHUP', stop);
  process.on('disconnect', stop);
  await gateway.start();
  if (process.connected) process.send({ type: 'listening' });
}

if (require.main === module) {
  main().catch(() => {
    process.stderr.write('codex-app-server-gateway: startup failed\n');
    process.exitCode = 1;
    if (process.connected) process.disconnect();
  });
}

module.exports = { AppServerGateway, SOCKET_PATH, dockerEnvironment, gatewayEnabled, startDaemon, websocketAccept };
