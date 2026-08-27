'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  DockerBridge,
  SSH_PATH,
  buildSshArgs,
  validateProcessIdentity,
  validateRemoteSocketPath,
} = require('./docker-bridge.js');
const {
  bridgeLaunch,
  closePromise,
  removeStaleSocket,
  validateGhcrRuntime,
  waitWithTimeout,
} = require('./supervisor.js');

const REMOTE_SOCKET = '/Users/imageyard/.docker/run/docker.sock';

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'imageyard-bridge-test-'));
  const socketDir = path.join(root, 'runtime');
  const socketPath = path.join(socketDir, 'docker.sock');
  fs.mkdirSync(socketDir, { mode: 0o700 });
  fs.chmodSync(socketDir, 0o700);
  return { root, socketDir, socketPath };
}

function removeFixture(root) {
  fs.rmSync(root, { recursive: true, force: true });
}

function collectConnection(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const socket = net.createConnection({ path: socketPath, allowHalfOpen: true });
    socket.on('connect', () => socket.end(payload));
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('end', () => {
      socket.destroy();
      resolve(Buffer.concat(chunks));
    });
    socket.on('error', reject);
  });
}

async function waitUntil(predicate, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error('timed out waiting for test condition');
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test('production SSH argv preserves the validated path without shell interpolation', () => {
  assert.equal(SSH_PATH, '/usr/bin/ssh');
  assert.deepEqual(buildSshArgs(REMOTE_SOCKET), [
    '-F',
    '/etc/ssh/ssh_config',
    '-T',
    '-o',
    'ClearAllForwardings=yes',
    '-o',
    'ControlMaster=no',
    '-o',
    'ControlPath=none',
    '--',
    'docker-host',
    'docker',
    '--host=unix:///Users/imageyard/.docker/run/docker.sock',
    'system',
    'dial-stdio',
  ]);
  assert.equal(validateRemoteSocketPath(REMOTE_SOCKET), REMOTE_SOCKET);
  for (const invalid of [
    '',
    'relative/docker.sock',
    '/tmp//docker.sock',
    '/tmp/../docker.sock',
    '/tmp/docker.sock/',
    '/tmp/docker socket',
    '/tmp/docker.sock;id',
    '/tmp/%2Fdocker.sock',
    '/tmp/docker.sock\n--bad',
  ]) {
    assert.throws(() => buildSshArgs(invalid), /invalid remote Docker socket path/);
  }
});

test('supervisor launch clears supplementary groups, ambient state, and privilege regain', () => {
  const launch = bridgeLaunch(REMOTE_SOCKET);
  assert.equal(launch.command, '/usr/bin/setpriv');
  assert.deepEqual(launch.args, [
    '--reuid=1000',
    '--regid=1000',
    '--clear-groups',
    '--no-new-privs',
    '--',
    '/usr/local/bin/node',
    '/usr/local/libexec/docker-bridge.js',
    REMOTE_SOCKET,
  ]);
  assert.deepEqual(launch.options.stdio, ['ignore', 'ignore', 'inherit', 'ipc']);
  assert.equal(launch.options.detached, false);
  assert.deepEqual(Object.keys(launch.options.env).sort(), [
    'HOME',
    'LANG',
    'LOGNAME',
    'PATH',
    'SHELL',
    'USER',
  ]);
  assert.equal('uid' in launch.options, false);
  assert.equal('gid' in launch.options, false);

  const safeStatus = 'CapEff:\t0000000000000000\nNoNewPrivs:\t1\n';
  assert.doesNotThrow(() => validateProcessIdentity(1000, 1000, [1000], safeStatus));
  assert.throws(
    () => validateProcessIdentity(1000, 1000, [0, 1000], safeStatus),
    /identity is invalid/,
  );
  assert.throws(
    () => validateProcessIdentity(
      1000,
      1000,
      [1000],
      'CapEff:\t0000000000000001\nNoNewPrivs:\t1\n',
    ),
    /privilege state is invalid/,
  );
  assert.throws(
    () => validateProcessIdentity(
      1000,
      1000,
      [1000],
      'CapEff:\t0000000000000000\nNoNewPrivs:\t0\n',
    ),
    /privilege state is invalid/,
  );
});

test('supervisor validates the runtime-only GHCR credential metadata contract', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'imageyard-ghcr-supervisor-test-'));
  const runtime = path.join(root, 'ghcr');
  const uid = process.getuid();
  const gid = process.getgid();
  try {
    fs.mkdirSync(runtime, { mode: 0o700 });
    fs.chmodSync(runtime, 0o700);
    for (const name of ['ghcr_username', 'ghcr_pat']) {
      fs.writeFileSync(path.join(runtime, name), 'runtime-only-fixture', { mode: 0o600 });
      fs.chmodSync(path.join(runtime, name), 0o600);
    }
    assert.doesNotThrow(() => validateGhcrRuntime(runtime, uid, gid));

    fs.chmodSync(path.join(runtime, 'ghcr_pat'), 0o644);
    assert.throws(() => validateGhcrRuntime(runtime, uid, gid), /credential is invalid/);
    fs.chmodSync(path.join(runtime, 'ghcr_pat'), 0o600);
    fs.writeFileSync(path.join(runtime, 'unexpected'), 'x', { mode: 0o600 });
    assert.throws(() => validateGhcrRuntime(runtime, uid, gid), /unexpected object/);
  } finally {
    fs.rmSync(root, { force: true, recursive: true });
  }
});

test('child close tracking does not confuse exit with completed process cleanup', async () => {
  const fake = new (require('node:events').EventEmitter)();
  const closed = closePromise(fake);
  fake.exitCode = 1;
  fake.signalCode = null;
  fake.emit('exit', 1, null);
  assert.equal(await waitWithTimeout(closed, 20), false);
  fake.emit('close', 1, null);
  assert.equal(await waitWithTimeout(closed, 100), true);
});

test('bridge relays concurrent binary half-closed streams with one sanitized child each', async () => {
  const files = fixture();
  const fake = path.join(files.root, 'fake-ssh.js');
  const stderrMarker = 'IMAGEYARD_FAKE_SSH_STDERR_MUST_BE_IGNORED';
  fs.writeFileSync(fake, [
    "'use strict';",
    `process.stderr.write(${JSON.stringify(stderrMarker)});`,
    "process.stdout.write(Buffer.from('HTTP/1.1 101 UPGRADED\\r\\nConnection: Upgrade\\r\\nUpgrade: tcp\\r\\n\\r\\n'));",
    'process.stdin.on(\'data\', (chunk) => process.stdout.write(chunk));',
    'process.stdin.on(\'end\', () => process.stdout.end());',
  ].join('\n'));

  let spawnCount = 0;
  const spawn = (command, args, options) => {
    spawnCount += 1;
    assert.equal(command, process.execPath);
    assert.deepEqual(args, [fake]);
    assert.equal(options.shell, false);
    assert.equal(options.detached, false);
    assert.deepEqual(options.stdio, ['pipe', 'pipe', 'ignore']);
    assert.equal(options.env.HOME, '/home/codex');
    assert.equal(options.env.PATH, '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin');
    assert.equal('NODE_OPTIONS' in options.env, false);
    assert.equal('NODE_PATH' in options.env, false);
    assert.equal('DOCKER_HOST' in options.env, false);
    return childProcess.spawn(command, args, options);
  };
  const bridge = new DockerBridge({
    socketDir: files.socketDir,
    socketPath: files.socketPath,
    remoteSocketPath: REMOTE_SOCKET,
    sshPath: process.execPath,
    sshArgs: [fake],
    spawn,
    socketCheckIntervalMs: 25,
  });

  try {
    await bridge.start();
    const socketStat = fs.lstatSync(files.socketPath);
    assert.equal(socketStat.isSocket(), true);
    assert.equal(socketStat.mode & 0o777, 0o600);

    const payloads = Array.from({ length: 8 }, (_, index) =>
      Buffer.from([0, index, 255, 10, 13, 65 + index]));
    const responses = await Promise.all(payloads.map((payload) =>
      collectConnection(files.socketPath, payload)));
    const header = Buffer.from('HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n');
    responses.forEach((response, index) => {
      assert.deepEqual(response, Buffer.concat([header, payloads[index]]));
      assert.equal(response.includes(Buffer.from(stderrMarker)), false);
    });
    assert.equal(spawnCount, payloads.length);
    await waitUntil(() => bridge.connections.size === 0);
  } finally {
    await bridge.stop();
    assert.equal(fs.existsSync(files.socketPath), false);
    removeFixture(files.root);
  }
});

test('per-request SSH exit is not bridge-fatal and a later request still succeeds', async () => {
  const files = fixture();
  const offline = path.join(files.root, 'offline.js');
  const echo = path.join(files.root, 'echo.js');
  fs.writeFileSync(offline, "process.stderr.write('SECRET_SSH_ERROR'); process.exit(255);\n");
  fs.writeFileSync(echo, "process.stdin.pipe(process.stdout);\n");
  let invocation = 0;
  let fatal = false;
  const bridge = new DockerBridge({
    socketDir: files.socketDir,
    socketPath: files.socketPath,
    remoteSocketPath: REMOTE_SOCKET,
    sshPath: process.execPath,
    sshArgs: [],
    spawn: (_command, _args, options) => {
      invocation += 1;
      return childProcess.spawn(process.execPath, [invocation === 1 ? offline : echo], options);
    },
    socketCheckIntervalMs: 25,
  });
  bridge.on('fatal', () => { fatal = true; });

  try {
    await bridge.start();
    assert.deepEqual(await collectConnection(files.socketPath, Buffer.from('first')), Buffer.alloc(0));
    assert.deepEqual(await collectConnection(files.socketPath, Buffer.from('second')), Buffer.from('second'));
    assert.equal(fatal, false);
    assert.equal(invocation, 2);
    await waitUntil(() => bridge.connections.size === 0);
  } finally {
    await bridge.stop();
    removeFixture(files.root);
  }
});

test('child stdin EPIPE does not truncate its surviving stdout direction', async () => {
  const files = fixture();
  const closesInput = path.join(files.root, 'closes-input.js');
  fs.writeFileSync(closesInput, [
    'process.stdin.destroy();',
    "setTimeout(() => process.stdout.end('stdout-after-stdin-close'), 50);",
  ].join('\n'));
  let fatal = false;
  const bridge = new DockerBridge({
    socketDir: files.socketDir,
    socketPath: files.socketPath,
    remoteSocketPath: REMOTE_SOCKET,
    sshPath: process.execPath,
    sshArgs: [closesInput],
    socketCheckIntervalMs: 25,
  });
  bridge.on('fatal', () => { fatal = true; });

  try {
    await bridge.start();
    const response = await collectConnection(files.socketPath, Buffer.alloc(1024 * 1024, 65));
    assert.equal(response.toString(), 'stdout-after-stdin-close');
    assert.equal(fatal, false);
    await waitUntil(() => bridge.connections.size === 0);
  } finally {
    await bridge.stop();
    removeFixture(files.root);
  }
});

test('shutdown applies bounded TERM then KILL and reaps a resistant child', async () => {
  const files = fixture();
  const resistant = path.join(files.root, 'resistant.js');
  fs.writeFileSync(resistant, [
    "process.on('SIGTERM', () => {});",
    "process.stdout.write('ready');",
    'process.stdin.resume();',
    'setInterval(() => {}, 1000);',
  ].join('\n'));
  let childPid;
  let resistantChild;
  const bridge = new DockerBridge({
    socketDir: files.socketDir,
    socketPath: files.socketPath,
    remoteSocketPath: REMOTE_SOCKET,
    sshPath: process.execPath,
    sshArgs: [resistant],
    childTermGraceMs: 100,
    socketCheckIntervalMs: 25,
    spawn: (command, args, options) => {
      const child = childProcess.spawn(command, args, options);
      resistantChild = child;
      childPid = child.pid;
      return child;
    },
  });
  let client;

  try {
    await bridge.start();
    client = net.createConnection({ path: files.socketPath });
    await new Promise((resolve, reject) => {
      client.once('connect', resolve);
      client.once('error', reject);
    });
    await waitUntil(() => bridge.connections.size === 1);
    await new Promise((resolve, reject) => {
      client.once('data', (chunk) => {
        try {
          assert.equal(chunk.toString(), 'ready');
          resolve();
        } catch (error) {
          reject(error);
        }
      });
      client.once('error', reject);
    });
    const started = Date.now();
    await bridge.stop();
    assert.ok(Date.now() - started >= 90);
    assert.ok(Date.now() - started < 1000);
    assert.equal(bridge.connections.size, 0);
    assert.equal(resistantChild.signalCode, 'SIGKILL');
    assert.throws(() => process.kill(childPid, 0), /ESRCH/);
  } finally {
    client?.destroy();
    await bridge.stop();
    removeFixture(files.root);
  }
});

test('socket replacement is fatal and inode-safe cleanup preserves the replacement', async () => {
  const files = fixture();
  const bridge = new DockerBridge({
    socketDir: files.socketDir,
    socketPath: files.socketPath,
    remoteSocketPath: REMOTE_SOCKET,
    socketCheckIntervalMs: 20,
  });
  const fatal = new Promise((resolve) => bridge.once('fatal', resolve));

  try {
    await bridge.start();
    fs.unlinkSync(files.socketPath);
    fs.writeFileSync(files.socketPath, 'replacement-must-survive');
    await Promise.race([
      fatal,
      new Promise((_, reject) => setTimeout(() => reject(new Error('socket replacement was not detected')), 1000)),
    ]);
    await bridge.stop();
    assert.equal(fs.readFileSync(files.socketPath, 'utf8'), 'replacement-must-survive');
  } finally {
    await bridge.stop();
    removeFixture(files.root);
  }
});

test('immediate shutdown revalidates identity before close and preserves a replacement', async () => {
  const files = fixture();
  const bridge = new DockerBridge({
    socketDir: files.socketDir,
    socketPath: files.socketPath,
    remoteSocketPath: REMOTE_SOCKET,
    socketCheckIntervalMs: 60000,
  });

  try {
    await bridge.start();
    fs.unlinkSync(files.socketPath);
    fs.writeFileSync(files.socketPath, 'immediate-replacement-must-survive');
    await bridge.stop();
    assert.equal(
      fs.readFileSync(files.socketPath, 'utf8'),
      'immediate-replacement-must-survive',
    );
  } finally {
    await bridge.stop();
    removeFixture(files.root);
  }
});

test('compromised bridge subprocess exits nonzero without unlinking the replacement', async () => {
  const files = fixture();
  const bridgeModule = require.resolve('./docker-bridge.js');
  const script = [
    "'use strict';",
    `const { DockerBridge, finishBridgeProcess } = require(${JSON.stringify(bridgeModule)});`,
    `const bridge = new DockerBridge(${JSON.stringify({
      socketDir: files.socketDir,
      socketPath: files.socketPath,
      remoteSocketPath: REMOTE_SOCKET,
      socketCheckIntervalMs: 60000,
    })});`,
    "process.on('message', (message) => {",
    "  if (message && message.type === 'finish') {",
    '    void finishBridgeProcess(bridge, 1);',
    '  }',
    '});',
    '(async () => {',
    '  await bridge.start();',
    "  process.send({ type: 'ready' });",
    '})().catch((error) => {',
    "  process.stderr.write(String(error));",
    '  process.exit(98);',
    '});',
  ].join('\n');
  const child = childProcess.spawn(process.execPath, ['-e', script], {
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const closed = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });

  try {
    await Promise.race([
      new Promise((resolve, reject) => {
        child.on('message', (message) => {
          if (message && message.type === 'ready') {
            resolve();
          }
        });
        child.once('close', (code, signal) => {
          reject(new Error(`bridge subprocess closed before readiness: ${code}/${signal}: ${stderr}`));
        });
      }),
      new Promise((_, reject) => setTimeout(() => reject(new Error('bridge subprocess readiness timed out')), 2000)),
    ]);
    fs.unlinkSync(files.socketPath);
    fs.writeFileSync(files.socketPath, 'subprocess-replacement-must-survive');
    child.send({ type: 'finish' });
    const result = await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error('bridge subprocess exit timed out')), 2000)),
    ]);
    assert.equal(result.code, 1, stderr);
    assert.equal(result.signal, null, stderr);
    assert.equal(
      fs.readFileSync(files.socketPath, 'utf8'),
      'subprocess-replacement-must-survive',
    );
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGKILL');
      await closed;
    }
    removeFixture(files.root);
  }
});

test('stale socket cleanup refuses live sockets, files, and symlinks', async () => {
  const files = fixture();
  const stale = path.join(files.root, 'stale.sock');
  const python = childProcess.spawnSync('python3', [
    '-c',
    'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()',
    stale,
  ]);
  assert.equal(python.status, 0, python.stderr.toString());
  assert.equal(fs.lstatSync(stale).isSocket(), true);
  fs.chmodSync(stale, 0o666);
  await assert.rejects(
    removeStaleSocket(stale, process.getuid(), process.getgid()),
    /stale socket metadata is invalid/,
  );
  assert.equal(fs.lstatSync(stale).isSocket(), true);
  fs.chmodSync(stale, 0o600);
  await removeStaleSocket(stale, process.getuid(), process.getgid());
  assert.equal(fs.existsSync(stale), false);

  const live = path.join(files.root, 'live.sock');
  const server = net.createServer((socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(live, resolve);
  });
  fs.chmodSync(live, 0o600);
  await assert.rejects(
    removeStaleSocket(live, process.getuid(), process.getgid()),
    /already live/,
  );
  assert.equal(fs.lstatSync(live).isSocket(), true);
  await new Promise((resolve) => server.close(resolve));

  const regular = path.join(files.root, 'regular');
  fs.writeFileSync(regular, 'keep');
  await assert.rejects(
    removeStaleSocket(regular, process.getuid(), process.getgid()),
    /unsafe object/,
  );
  assert.equal(fs.readFileSync(regular, 'utf8'), 'keep');

  const target = path.join(files.root, 'target');
  const symlink = path.join(files.root, 'symlink');
  fs.writeFileSync(target, 'target');
  fs.symlinkSync(target, symlink);
  await assert.rejects(
    removeStaleSocket(symlink, process.getuid(), process.getgid()),
    /unsafe object/,
  );
  assert.equal(fs.lstatSync(symlink).isSymbolicLink(), true);
  removeFixture(files.root);
});
