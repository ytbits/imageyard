import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import type { Socket } from 'node:net';
import { Duplex } from 'node:stream';
import WebSocket from 'ws';
import { AppServerClient } from './client.ts';

// Isolated fixture only: the desktop-style proxy relays raw Unix-socket bytes.
// Its stdio therefore carries HTTP Upgrade + WebSocket frames, NOT JSON lines.
// This check attaches to an already-running daemon and never creates a thread.
const child = spawn('codex', ['app-server', 'proxy'], {
  detached: true, stdio: ['pipe', 'pipe', 'ignore'],
});
const exited = new Promise<number | null>((resolve) => {
  child.once('error', () => resolve(null));
  child.once('close', (code) => resolve(code));
});
child.stdin.on('error', () => {});
const transport = Duplex.from({ readable: child.stdout, writable: child.stdin });
transport.on('error', () => {});
const socket = new WebSocket('ws://localhost/', {
  // No TCP connection is opened; this stream is the authenticated SSH proxy pipe.
  createConnection: () => transport as Socket,
  handshakeTimeout: 5_000,
  perMessageDeflate: false,
  maxPayload: 16 * 1024 * 1024,
});
socket.on('error', () => {});
const closed = new Promise<void>((resolve) => socket.once('close', () => resolve()));
let phase = 'WebSocket upgrade';
let networkClient: AppServerClient | undefined;
let response: { id: number; resolve: (value: unknown) => void; reject: (error: Error) => void } | undefined;

function terminateGroup(signal: NodeJS.Signals) {
  if (!child.pid) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
  }
}

async function bounded<T>(promise: Promise<T>, milliseconds: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Protocol deadline exceeded.')), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

socket.on('message', (data, binary) => {
  try {
    if (binary) throw new Error('Unexpected binary RPC payload.');
    const message = JSON.parse(data.toString());
    if (!response || message.id !== response.id) return;
    if (message.error || !message.result) throw new Error('RPC rejected.');
    const pending = response;
    response = undefined;
    pending.resolve(message.result);
  } catch (error) { response?.reject(error as Error); }
});
socket.on('error', () => response?.reject(new Error('Proxy transport failed.')));
socket.on('close', () => response?.reject(new Error('Proxy transport closed.')));

function request(id: number, method: string, params: object): Promise<unknown> {
  return bounded(new Promise((resolve, reject) => {
    response = { id, resolve, reject };
    socket.send(JSON.stringify({ id, method, params }));
  }), 5_000);
}

try {
  await bounded(new Promise<void>((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  }), 6_000);
  phase = 'initialize';
  await request(1, 'initialize', { clientInfo: { name: 'imageyard_proxy_smoke', version: '1.0.0' } });
  socket.send(JSON.stringify({ method: 'initialized' }));
  if (process.env.CODEX_APP_SERVER_URL) {
    phase = 'concurrent network connection';
    const tokenFile = process.env.CODEX_APP_SERVER_TOKEN_FILE;
    if (!tokenFile) throw new Error('Network fixture token file required.');
    networkClient = await AppServerClient.connect({
      url: process.env.CODEX_APP_SERVER_URL,
      token: readFileSync(tokenFile, 'utf8').trim(),
      tlsServerName: process.env.CODEX_APP_SERVER_TLS_SERVER_NAME,
      ca: process.env.CODEX_APP_SERVER_CA_FILE ? readFileSync(process.env.CODEX_APP_SERVER_CA_FILE) : undefined,
      requestTimeoutMs: 5_000,
    });
    assert.ok((await networkClient.request('config/read', { includeLayers: false })).config);
  }
  phase = 'config/read';
  const result = await request(2, 'config/read', { includeLayers: false }) as { config?: object };
  assert.ok(result.config && typeof result.config === 'object');
  if (networkClient) {
    assert.ok(Array.isArray((await networkClient.request('thread/list', { limit: 1, useStateDbOnly: true })).data));
  }
  phase = 'WebSocket close';
  socket.close();
  // The byte proxy waits for both copy directions. Flush the queued close frame
  // then EOF its stdin; waiting for process/stdout close before EOF deadlocks.
  transport.end();
  await bounded(closed, 3_000);
  phase = 'proxy exit';
  assert.equal(await bounded(exited, 3_000), 0);
  console.log('App Server desktop proxy WebSocket protocol passed.');
} catch {
  console.error(`App Server desktop proxy smoke failed during ${phase}.`);
  process.exitCode = 1;
} finally {
  networkClient?.close();
  socket.terminate();
  transport.destroy();
  terminateGroup('SIGTERM');
  try { await bounded(exited, 1_000); } catch { terminateGroup('SIGKILL'); }
  // The group can outlive its CLI wrapper; remove only this detached fixture group.
  terminateGroup('SIGKILL');
}
