import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test, type TestContext } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket, { WebSocketServer } from 'ws';
import { AppServerClient, OutcomeUnknownError, RpcError, type JsonObject } from './client.ts';

// Test-generated short-lived identity; no production credentials or models.
const directory = mkdtempSync(join(tmpdir(), 'imageyard-client-test-'));
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
  '-subj', '/CN=app-server.test', '-addext', 'subjectAltName=DNS:app-server.test',
  '-keyout', join(directory, 'key.pem'), '-out', join(directory, 'cert.pem')],
{ stdio: 'ignore' });
const cert = readFileSync(join(directory, 'cert.pem'));
const key = readFileSync(join(directory, 'key.pem'));
after(() => rmSync(directory, { recursive: true, force: true }));

type Message = JsonObject & { method?: string; id?: string | number; params?: JsonObject };
const send = (socket: WebSocket, message: unknown) => socket.send(JSON.stringify(message));

async function fixture(t: TestContext, handle: (socket: WebSocket, message: Message) => void) {
  const server = createServer({ cert, key });
  const wss = new WebSocketServer({ server });
  const messages: Message[] = [];
  const sockets: WebSocket[] = [];
  wss.on('connection', (socket, request) => {
    assert.equal(request.headers.authorization, 'Bearer test-token');
    sockets.push(socket);
    socket.on('message', (data) => {
      const message = JSON.parse(data.toString()) as Message;
      messages.push(message);
      if (message.method === 'initialize') send(socket, { id: message.id, result: {} });
      else handle(socket, message);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    for (const socket of wss.clients) socket.terminate();
    await new Promise<void>((resolve) => wss.close(() => server.close(() => resolve())));
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing test address');
  const options = {
    url: `wss://127.0.0.1:${address.port}/`, token: 'test-token',
    tlsServerName: 'app-server.test', ca: cert, requestTimeoutMs: 1_000,
  };
  return { options, messages, sockets };
}

test('initializes, correlates replies, resumes one thread, steers and interrupts', async (t) => {
  const fixtureData = await fixture(t, (socket, message) => {
    if (message.method === 'initialized') return;
    if (message.method === 'thread/start' || message.method === 'thread/resume') {
      send(socket, { id: message.id, result: { thread: { id: 'thread-one', turns: [] } } });
    } else if (message.method === 'turn/start') {
      send(socket, { id: message.id, result: { turn: { id: 'turn-one', status: 'inProgress', items: [] } } });
    } else send(socket, { id: message.id, result: { method: message.method } });
  });
  const client = await AppServerClient.connect(fixtureData.options);
  t.after(() => client.close());
  assert.equal((await client.startThread()).thread.id, 'thread-one');
  assert.equal((await client.resumeThread('thread-one')).thread.id, 'thread-one');
  assert.equal((await client.startTurn('thread-one', 'Research card')).id, 'turn-one');
  const [steer, interrupt] = await Promise.all([
    client.steerTurn('thread-one', 'turn-one', 'Canada only'),
    client.interruptTurn('thread-one', 'turn-one'),
  ]);
  assert.equal(steer.method, 'turn/steer');
  assert.equal(interrupt.method, 'turn/interrupt');
  assert.deepEqual(fixtureData.messages.slice(0, 3).map((message) => message.method),
    ['initialize', 'initialized', 'thread/start']);
  assert.equal(fixtureData.messages.find((message) => message.method === 'turn/steer')?.params?.expectedTurnId, 'turn-one');
  await assert.rejects(client.request('initialize'), /initialize exactly once/);
});

test('captures completion arriving before the start reply and keeps failed distinct', async (t) => {
  const events: string[] = [];
  const f = await fixture(t, (socket, message) => {
    if (message.method !== 'turn/start') return;
    send(socket, { method: 'turn/completed', params: {
      threadId: 'thread-one', turn: { id: 'turn-one', status: 'failed', items: [], error: { message: 'fixture' } },
    } });
    send(socket, { id: message.id, result: { turn: { id: 'turn-one', status: 'inProgress', items: [] } } });
  });
  const client = await AppServerClient.connect({ ...f.options, onNotification: (event) => events.push(event.method) });
  t.after(() => client.close());
  const started = await client.startTurn('thread-one', 'Fixture');
  const completed = await client.waitForTurn('thread-one', started.id);
  assert.equal(completed.status, 'failed');
  assert.deepEqual(events, ['turn/completed']);
});

test('answers clarification and explicit decline using the server request id', async (t) => {
  const received: Message[] = [];
  const f = await fixture(t, (_socket, message) => { if (!message.method) received.push(message); });
  const client = await AppServerClient.connect({
    ...f.options, experimentalApi: true,
    onServerRequest: async (request) => {
      if (request.method === 'item/tool/requestUserInput') return { answers: { market: { answers: ['Canada'] } } };
      if (request.method === 'item/commandExecution/requestApproval') return { decision: 'decline' };
      throw new RpcError(-32601, 'Unsupported');
    },
  });
  t.after(() => client.close());
  const socket = f.sockets[0];
  send(socket, { id: 1, method: 'item/tool/requestUserInput', params: { questions: [] } });
  send(socket, { id: 'approval', method: 'item/commandExecution/requestApproval', params: {} });
  send(socket, { id: 'unsupported', method: 'unknown/request', params: {} });
  for (let i = 0; received.length < 3 && i < 100; i++) await delay(5);
  assert.equal(received.length, 3);
  assert.deepEqual(received.find((message) => message.id === 1)?.result, { answers: { market: { answers: ['Canada'] } } });
  assert.deepEqual(received.find((message) => message.id === 'approval')?.result, { decision: 'decline' });
  assert.equal((received.find((message) => message.id === 'unsupported')?.error as JsonObject).code, -32601);
});

test('aborts stale questions after server resolution and does not answer twice', async (t) => {
  let signal: AbortSignal | undefined;
  let release!: (answer: unknown) => void;
  const f = await fixture(t, () => {});
  const client = await AppServerClient.connect({ ...f.options, onServerRequest: async (_request, abortSignal) => {
    signal = abortSignal;
    return new Promise((resolve) => { release = resolve; });
  } });
  t.after(() => client.close());
  send(f.sockets[0], { id: 'question', method: 'item/tool/requestUserInput', params: {} });
  for (let i = 0; !signal && i < 100; i++) await delay(5);
  assert.ok(signal);
  send(f.sockets[0], { method: 'serverRequest/resolved', params: { requestId: 'question' } });
  for (let i = 0; !signal.aborted && i < 100; i++) await delay(5);
  assert.equal(signal.aborted, true);
  release({ answers: {} });
  await delay(20);
  assert.equal(f.messages.filter((message) => message.id === 'question').length, 0);
});

test('surfaces RPC errors, rejects disconnect waiters, reconnects without replay', async (t) => {
  const f = await fixture(t, (socket, message) => {
    if (message.method === 'thread/read') send(socket, { id: message.id, error: { code: -32000, message: 'Not found' } });
    if (message.method === 'thread/resume') send(socket, { id: message.id, result: { thread: { id: 'saved', turns: [] } } });
  });
  const first = await AppServerClient.connect(f.options);
  await assert.rejects(first.request('thread/read'), (error: unknown) => error instanceof RpcError && error.code === -32000);
  const requestFailure = assert.rejects(first.startTurn('saved', 'Once only'), OutcomeUnknownError);
  const turnFailure = assert.rejects(first.waitForTurn('saved', 'pending'), OutcomeUnknownError);
  f.sockets[0].terminate();
  await Promise.all([requestFailure, turnFailure]);
  const second = await AppServerClient.connect(f.options);
  t.after(() => second.close());
  await second.resumeThread('saved');
  assert.equal(f.messages.filter((message) => message.method === 'initialize').length, 2);
  assert.ok(f.messages.filter((message) => message.method === 'turn/start').length <= 1);
});

test('request and turn deadlines are bounded and do not replay mutations', async (t) => {
  const f = await fixture(t, () => {});
  const client = await AppServerClient.connect({ ...f.options, requestTimeoutMs: 30 });
  t.after(() => client.close());
  await assert.rejects(client.startTurn('saved', 'Once only'), OutcomeUnknownError);
  await assert.rejects(client.waitForTurn('saved', 'pending', 20), OutcomeUnknownError);
  assert.equal(f.messages.filter((message) => message.method === 'turn/start').length, 1);
});

test('enforces WSS, trusted CA and certificate identity', async (t) => {
  const f = await fixture(t, () => {});
  await assert.rejects(AppServerClient.connect({ ...f.options, url: f.options.url.replace('wss:', 'ws:') }), /WSS/);
  await assert.rejects(AppServerClient.connect({ ...f.options, ca: undefined }), /connection failed/);
  await assert.rejects(AppServerClient.connect({ ...f.options, tlsServerName: 'wrong.test' }), /connection failed/);
});

test('unsupported server requests are rejected by default; malformed traffic fails pending calls', async (t) => {
  let rejected: Message | undefined;
  const f = await fixture(t, (_socket, message) => { if (!message.method) rejected = message; });
  const client = await AppServerClient.connect(f.options);
  t.after(() => client.close());
  send(f.sockets[0], { id: 'approval', method: 'item/commandExecution/requestApproval', params: {} });
  for (let i = 0; !rejected && i < 100; i++) await delay(5);
  assert.equal((rejected?.error as JsonObject).code, -32601);
  const failure = assert.rejects(client.request('thread/list'), OutcomeUnknownError);
  f.sockets[0].send('invalid-json');
  await failure;
});
