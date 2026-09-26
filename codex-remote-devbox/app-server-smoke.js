#!/usr/local/bin/node
'use strict';

// Test-only client, streamed into an authenticated SSH session by smoke-test.sh.
const { execFileSync, spawn } = require('node:child_process');
const fs = require('node:fs');

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function assertTcpListeners() {
  let output;
  try {
    output = execFileSync('ss', ['-H', '-lnt'], {
      encoding: 'utf8', timeout: 5000, maxBuffer: 65536, stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch {
    throw new Error('could not inspect app-server TCP listeners');
  }
  let sshListeners = 0;
  let dockerDnsListeners = 0;
  for (const line of output.trim().split('\n').filter(Boolean)) {
    const address = line.trim().split(/\s+/)[3];
    if (/:2222$/.test(address)) sshListeners += 1;
    else if (/^127\.0\.0\.11:/.test(address)) dockerDnsListeners += 1;
    else throw new Error('unexpected TCP listener during app-server smoke');
  }
  requireCondition(sshListeners > 0 && dockerDnsListeners <= 1,
    'unexpected SSH or Docker DNS listener count');
}

function signalGroup(child, signal) {
  if (!child.pid) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}

function groupExists(child) {
  if (!child.pid) return false;
  try { process.kill(-child.pid, 0); return true; } catch (error) {
    if (error.code === 'ESRCH') return false;
    throw error;
  }
}

function assertNoCodexProcess() {
  try {
    execFileSync('pgrep', ['-u', '1000', '-x', 'codex'], {
      timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    if (error.status === 1) return;
    throw new Error('could not inspect remaining Codex processes');
  }
  throw new Error('unexpected Codex process outside an app-server session');
}

async function main() {
  requireCondition(process.argv.length === 3 && /^\d+\.\d+\.\d+$/.test(process.argv[2]),
    'one exact stable Codex version is required');
  const expectedVersion = process.argv[2];
  requireCondition(process.getuid() === 1000 && process.getgid() === 1000,
    'app-server smoke must run as codex');
  requireCondition(process.env.HOME === '/home/codex' && !process.env.CODEX_HOME,
    'app-server smoke requires the default SSH Home');
  requireCondition(!fs.existsSync('/home/codex/.codex/auth.json'),
    'app-server smoke must use an unauthenticated fixture');
  assertNoCodexProcess();
  assertTcpListeners();

  const child = spawn('codex', ['app-server'], {
    detached: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let phase = 'initialize';
  let failure;
  let buffered = '';
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let killTimer;
  let exitTimer;
  const fail = (error) => {
    if (failure) return;
    failure = error;
    child.stdin.destroy();
    signalGroup(child, 'SIGTERM');
    killTimer = setTimeout(() => signalGroup(child, 'SIGKILL'), 2000);
    exitTimer = setTimeout(() => {
      process.stderr.write('app-server-smoke: failed to reap app-server after deadline\n');
      process.exit(1);
    }, 3000);
  };
  const onSignal = () => fail(new Error('app-server smoke interrupted'));
  process.once('SIGTERM', onSignal);
  process.once('SIGINT', onSignal);
  const deadline = setTimeout(() => fail(new Error('app-server protocol deadline exceeded')), 30000);
  const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);

  child.stdin.on('error', () => fail(new Error('app-server input failed')));
  // Never expose server diagnostics or config values in release logs.
  child.stderr.on('data', (chunk) => {
    stderrBytes += chunk.length;
    if (stderrBytes > 1048576) fail(new Error('app-server diagnostics exceeded the limit'));
  });
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    if (failure) return;
    try {
      stdoutBytes += Buffer.byteLength(chunk);
      requireCondition(stdoutBytes <= 1048576, 'app-server protocol exceeded the limit');
      buffered += chunk;
      let newline;
      while ((newline = buffered.indexOf('\n')) !== -1) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        const message = JSON.parse(line);
        requireCondition(message && typeof message === 'object', 'invalid app-server message');
        if (!Object.hasOwn(message, 'id')) {
          requireCondition(typeof message.method === 'string', 'invalid app-server notification');
          continue;
        }
        requireCondition(!Object.hasOwn(message, 'error'), 'app-server rejected a smoke request');
        if (phase === 'initialize' && message.id === 1) {
          const result = message.result;
          requireCondition(result?.userAgent?.startsWith(`imageyard_smoke/${expectedVersion} (`),
            'app-server reported an unexpected version');
          requireCondition(result.codexHome === '/home/codex/.codex',
            'app-server reported an unexpected Home');
          requireCondition(result.platformFamily === 'unix' && result.platformOs === 'linux',
            'app-server reported an unexpected platform');
          phase = 'config';
          send({ method: 'initialized' });
          send({ id: 2, method: 'config/read', params: { includeLayers: false } });
        } else if (phase === 'config' && message.id === 2) {
          requireCondition(message.result?.config && typeof message.result.config === 'object',
            'app-server did not acknowledge an initialized config request');
          assertTcpListeners();
          phase = 'shutdown';
          child.stdin.end();
        } else throw new Error('unexpected app-server protocol response');
      }
    } catch (error) { fail(error); }
  });

  const exited = new Promise((resolve) => {
    child.once('error', () => fail(new Error('app-server spawn failed')));
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  send({ id: 1, method: 'initialize', params: {
    clientInfo: { name: 'imageyard_smoke', version: '1.0.0' },
  } });
  const result = await exited;
  clearTimeout(deadline);
  clearTimeout(killTimer);
  clearTimeout(exitTimer);
  process.removeListener('SIGTERM', onSignal);
  process.removeListener('SIGINT', onSignal);
  if (groupExists(child)) {
    signalGroup(child, 'SIGKILL');
    throw new Error('app-server left a process behind');
  }
  if (failure) throw failure;
  requireCondition(phase === 'shutdown' && result.code === 0 && result.signal === null,
    'app-server did not shut down cleanly after protocol completion');
  requireCondition(buffered.trim() === '', 'incomplete app-server protocol message');
  requireCondition(!fs.existsSync('/home/codex/.codex/auth.json'),
    'app-server smoke unexpectedly created authentication state');
  assertNoCodexProcess();
  assertTcpListeners();
  process.stdout.write(`app-server-smoke: ok ${expectedVersion} /home/codex/.codex linux\n`);
}

main().catch((error) => {
  // Messages are test-owned; do not print parser errors that could include data.
  const safeMessage = error instanceof SyntaxError ? 'invalid app-server JSON' : error.message;
  process.stderr.write(`app-server-smoke: ${safeMessage}\n`);
  process.exitCode = 1;
});
