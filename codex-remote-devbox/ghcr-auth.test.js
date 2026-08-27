'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  applyAction,
  configureGhcrAuth,
  readDockerConfig,
} = require('./ghcr-auth-config.js');
const {
  handleCommand,
  loadCredential,
  normalizeServerInput,
  readRuntimeScalar,
} = require('./ghcr-credential-helper.js');

const uid = process.getuid();
const gid = process.getgid();
const username = 'imageyard-smoke';
const token = 'ghp_IMAGEYARD_RUNTIME_ONLY_TEST_TOKEN_0123456789';

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'imageyard-ghcr-auth-test-'));
  const home = path.join(root, 'home');
  const dockerDirectory = path.join(home, '.docker');
  const configPath = path.join(dockerDirectory, 'config.json');
  const runtime = path.join(root, 'runtime');
  fs.mkdirSync(home, { mode: 0o700 });
  fs.mkdirSync(runtime, { mode: 0o700 });
  fs.chmodSync(home, 0o700);
  fs.chmodSync(runtime, 0o700);
  fs.writeFileSync(path.join(runtime, 'ghcr_username'), username, { mode: 0o600 });
  fs.writeFileSync(path.join(runtime, 'ghcr_pat'), token, { mode: 0o600 });
  fs.chmodSync(path.join(runtime, 'ghcr_username'), 0o600);
  fs.chmodSync(path.join(runtime, 'ghcr_pat'), 0o600);
  return { configPath, dockerDirectory, home, root, runtime };
}

function cleanup(root) {
  fs.rmSync(root, { force: true, recursive: true });
}

function writeConfig(files, config, mode = 0o600) {
  fs.mkdirSync(files.dockerDirectory, { mode: 0o700, recursive: true });
  fs.writeFileSync(files.configPath, JSON.stringify(config), { mode });
  fs.chmodSync(files.configPath, mode);
}

function readConfig(files) {
  return JSON.parse(fs.readFileSync(files.configPath, 'utf8'));
}

function assertNoTemporaryFiles(files) {
  assert.deepEqual(
    fs.readdirSync(files.dockerDirectory).filter((name) => name.startsWith('.config.json.codex-ghcr.')),
    [],
  );
}

test('credential helper returns only the runtime GHCR credential for get and list', () => {
  const files = fixture();
  try {
    assert.deepEqual(loadCredential(files.runtime, uid, gid), { secret: token, username });
    assert.equal(normalizeServerInput('ghcr.io\n'), 'ghcr.io');
    assert.equal(normalizeServerInput('https://ghcr.io/v1/'), 'ghcr.io');
    assert.deepEqual(JSON.parse(handleCommand('get', 'ghcr.io\n', files.runtime, uid, gid)), {
      Secret: token,
      Username: username,
    });
    assert.deepEqual(JSON.parse(handleCommand('list', '', files.runtime, uid, gid)), {
      'ghcr.io': username,
    });
    for (const server of ['docker.io', 'ghcr.io/other', 'ghcr.io\nother']) {
      assert.throws(
        () => handleCommand('get', server, files.runtime, uid, gid),
        /credential server/,
      );
    }
    for (const command of ['store', 'erase', 'unknown']) {
      assert.throws(() => handleCommand(command, '', files.runtime, uid, gid));
    }
    assert.throws(
      () => handleCommand('get', 'x'.repeat(4097), files.runtime, uid, gid),
      /input is too large/,
    );
  } finally {
    cleanup(files.root);
  }
});

test('credential helper rejects unsafe runtime paths, metadata, and malformed values', () => {
  const files = fixture();
  try {
    fs.chmodSync(path.join(files.runtime, 'ghcr_pat'), 0o644);
    assert.throws(() => loadCredential(files.runtime, uid, gid), /credential file is invalid/);
    fs.chmodSync(path.join(files.runtime, 'ghcr_pat'), 0o600);
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), 'short', { mode: 0o600 });
    assert.throws(() => loadCredential(files.runtime, uid, gid), /credential file is invalid/);
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), `${token}\n`, { mode: 0o600 });
    assert.throws(() => loadCredential(files.runtime, uid, gid), /credential value is invalid/);
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), token, { mode: 0o600 });
    fs.writeFileSync(path.join(files.runtime, 'ghcr_username'), Buffer.from([0xc1]), { mode: 0o600 });
    assert.throws(() => loadCredential(files.runtime, uid, gid), /credential value is invalid/);
    fs.writeFileSync(path.join(files.runtime, 'ghcr_username'), username, { mode: 0o600 });
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), Buffer.alloc(20, 0xe1), { mode: 0o600 });
    assert.throws(() => loadCredential(files.runtime, uid, gid), /credential value is invalid/);
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), token, { mode: 0o600 });
    assert.throws(
      () => readRuntimeScalar(
        path.join(files.runtime, 'ghcr_pat'),
        uid,
        gid,
        20,
        512,
        /^[!-~]+$/,
        { afterOpen: (filePath) => fs.writeFileSync(filePath, 'x', { mode: 0o600 }) },
      ),
      /credential value is invalid/,
    );
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), token, { mode: 0o600 });
    assert.throws(
      () => readRuntimeScalar(
        path.join(files.runtime, 'ghcr_pat'),
        uid,
        gid,
        20,
        512,
        /^[!-~]+$/,
        { afterRead: (filePath) => fs.writeFileSync(filePath, 'short', { mode: 0o600 }) },
      ),
      /credential value is invalid/,
    );
    fs.writeFileSync(path.join(files.runtime, 'ghcr_pat'), token, { mode: 0o600 });
    fs.unlinkSync(path.join(files.runtime, 'ghcr_username'));
    fs.symlinkSync('ghcr_pat', path.join(files.runtime, 'ghcr_username'));
    assert.throws(() => loadCredential(files.runtime, uid, gid), /credential file is invalid/);
  } finally {
    cleanup(files.root);
  }
});

test('enable preserves unrelated Docker state and an existing legacy GHCR auth', () => {
  const files = fixture();
  try {
    fs.mkdirSync(files.dockerDirectory, { mode: 0o755 });
    const original = {
      auths: {
        'ghcr.io': { auth: 'legacy-secret-preserved-until-explicit-scrub' },
        'registry.example.test': { auth: 'unrelated-auth' },
      },
      credHelpers: { 'registry.example.test': 'pass' },
      currentContext: 'preserved-context',
      plugins: { buildx: { enabled: 'true' } },
    };
    fs.writeFileSync(files.configPath, JSON.stringify(original), { mode: 0o644 });
    configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid);

    assert.equal(fs.lstatSync(files.configPath).mode & 0o777, 0o600);
    assert.equal(fs.lstatSync(files.dockerDirectory).mode & 0o777, 0o700);
    assert.deepEqual(readConfig(files), {
      ...original,
      credHelpers: {
        'ghcr.io': 'codex-ghcr',
        'registry.example.test': 'pass',
      },
    });
    assert.equal(fs.readFileSync(files.configPath, 'utf8').includes(token), false);

    const firstStat = fs.statSync(files.configPath);
    configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid);
    const secondStat = fs.statSync(files.configPath);
    assert.equal(secondStat.ino, firstStat.ino);
    assert.equal(secondStat.mtimeMs, firstStat.mtimeMs);
  } finally {
    cleanup(files.root);
  }
});

test('scrub-legacy-auth removes only exact auths[ghcr.io], including a quoted JSON key', () => {
  const files = fixture();
  try {
    fs.mkdirSync(files.dockerDirectory, { mode: 0o700 });
    fs.writeFileSync(
      files.configPath,
      '{"auths":{"\\u0067hcr.io":{"auth":"legacy"},"https://ghcr.io/v1/":{"auth":"preserved"},"other":{"auth":"keep"}},"credHelpers":{"ghcr.io":"codex-ghcr"},"custom":true}',
      { mode: 0o600 },
    );
    configureGhcrAuth('scrub-legacy-auth', files.dockerDirectory, files.configPath, uid, gid);
    assert.deepEqual(readConfig(files), {
      auths: {
        'https://ghcr.io/v1/': { auth: 'preserved' },
        other: { auth: 'keep' },
      },
      credHelpers: { 'ghcr.io': 'codex-ghcr' },
      custom: true,
    });
    const firstStat = fs.statSync(files.configPath);
    configureGhcrAuth('scrub-legacy-auth', files.dockerDirectory, files.configPath, uid, gid);
    assert.equal(fs.statSync(files.configPath).ino, firstStat.ino);
  } finally {
    cleanup(files.root);
  }
});

test('disable removes only the exact image-managed helper mapping and is idempotent', () => {
  const files = fixture();
  try {
    const original = {
      auths: { 'ghcr.io': { auth: 'legacy-fallback' } },
      credHelpers: { 'ghcr.io': 'codex-ghcr', other: 'pass' },
      custom: { keep: true },
    };
    writeConfig(files, original, 0o644);
    configureGhcrAuth('disable', files.dockerDirectory, files.configPath, uid, gid);
    assert.equal(fs.lstatSync(files.configPath).mode & 0o777, 0o600);
    assert.deepEqual(readConfig(files), {
      auths: original.auths,
      credHelpers: { other: 'pass' },
      custom: { keep: true },
    });
    const firstStat = fs.statSync(files.configPath);
    configureGhcrAuth('disable', files.dockerDirectory, files.configPath, uid, gid);
    assert.equal(fs.statSync(files.configPath).ino, firstStat.ino);

    writeConfig(files, { credHelpers: { 'ghcr.io': 'user-managed-helper' } });
    assert.throws(
      () => configureGhcrAuth('disable', files.dockerDirectory, files.configPath, uid, gid),
      /not image-managed/,
    );
    assert.deepEqual(readConfig(files), { credHelpers: { 'ghcr.io': 'user-managed-helper' } });
    assert.throws(
      () => configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid),
      /not image-managed/,
    );
    assert.deepEqual(readConfig(files), { credHelpers: { 'ghcr.io': 'user-managed-helper' } });
  } finally {
    cleanup(files.root);
  }
});

test('fresh enable creates a minimal config while fresh disable and scrub create no config', () => {
  for (const action of ['disable', 'scrub-legacy-auth']) {
    const files = fixture();
    try {
      configureGhcrAuth(action, files.dockerDirectory, files.configPath, uid, gid);
      assert.equal(fs.existsSync(files.configPath), false);
    } finally {
      cleanup(files.root);
    }
  }
  const files = fixture();
  try {
    configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid);
    assert.deepEqual(readConfig(files), { credHelpers: { 'ghcr.io': 'codex-ghcr' } });
    assert.equal(fs.readFileSync(files.configPath, 'utf8').includes(token), false);
  } finally {
    cleanup(files.root);
  }
});

test('config actions reject malformed and hostile existing Home state', () => {
  const files = fixture();
  try {
    fs.mkdirSync(files.dockerDirectory, { mode: 0o700 });
    fs.writeFileSync(files.configPath, '{not-json', { mode: 0o600 });
    assert.throws(
      () => configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid),
      SyntaxError,
    );
    fs.writeFileSync(files.configPath, JSON.stringify({ credHelpers: 'unsafe' }), { mode: 0o600 });
    assert.throws(
      () => configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid),
      /credHelpers configuration/,
    );
    fs.unlinkSync(files.configPath);
    fs.symlinkSync('/dev/null', files.configPath);
    assert.throws(
      () => configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid),
      /configuration file is unsafe/,
    );
  } finally {
    cleanup(files.root);
  }
});

test('config reader rejects invalid UTF-8 and hardlink topology without mutation', () => {
  const files = fixture();
  try {
    fs.mkdirSync(files.dockerDirectory, { mode: 0o700 });
    const invalidUtf8 = Buffer.concat([
      Buffer.from('{"custom":"', 'ascii'),
      Buffer.from([0xff]),
      Buffer.from('"}\n', 'ascii'),
    ]);
    fs.writeFileSync(files.configPath, invalidUtf8, { mode: 0o600 });
    assert.throws(
      () => configureGhcrAuth('enable', files.dockerDirectory, files.configPath, uid, gid),
      /not valid UTF-8/,
    );
    assert.deepEqual(fs.readFileSync(files.configPath), invalidUtf8);
    assertNoTemporaryFiles(files);

    fs.writeFileSync(files.configPath, '{"currentContext":"before"}\n', { mode: 0o600 });
    assert.throws(
      () => readDockerConfig(
        files.configPath,
        uid,
        gid,
        {
          afterRead: (configPath) => {
            fs.writeFileSync(configPath, '{"currentContext":"concurrent"}\n', { mode: 0o600 });
          },
        },
      ),
      /changed during read/,
    );
    assert.deepEqual(readConfig(files), { currentContext: 'concurrent' });

    const original = '{"auths":{"ghcr.io":{"auth":"legacy"}},"credHelpers":{"ghcr.io":"codex-ghcr"}}\n';
    fs.writeFileSync(files.configPath, original, { mode: 0o600 });
    const sibling = path.join(files.dockerDirectory, 'config-hardlink.json');
    fs.linkSync(files.configPath, sibling);
    assert.throws(
      () => configureGhcrAuth('scrub-legacy-auth', files.dockerDirectory, files.configPath, uid, gid),
      /configuration file is unsafe/,
    );
    assert.equal(fs.readFileSync(files.configPath, 'utf8'), original);
    assert.equal(fs.readFileSync(sibling, 'utf8'), original);
    assert.equal(fs.lstatSync(files.configPath).nlink, 2);
    assertNoTemporaryFiles(files);
  } finally {
    cleanup(files.root);
  }
});

test('atomic disable detects a replacement injected before its final identity check', () => {
  const files = fixture();
  try {
    writeConfig(files, {
      credHelpers: { 'ghcr.io': 'codex-ghcr' },
      currentContext: 'before',
    });
    assert.throws(
      () => configureGhcrAuth(
        'disable',
        files.dockerDirectory,
        files.configPath,
        uid,
        gid,
        {
          afterTemporarySync: () => {
            fs.writeFileSync(files.configPath, '{"currentContext":"concurrent"}\n', { mode: 0o600 });
          },
        },
      ),
      /changed concurrently/,
    );
    assert.deepEqual(readConfig(files), { currentContext: 'concurrent' });
    assertNoTemporaryFiles(files);
  } finally {
    cleanup(files.root);
  }
});

test('pre-rename disable failure leaves the original config intact and cleans the temporary file', () => {
  const files = fixture();
  try {
    const original = '{"credHelpers":{"ghcr.io":"codex-ghcr"},"currentContext":"original"}\n';
    fs.mkdirSync(files.dockerDirectory, { mode: 0o700 });
    fs.writeFileSync(files.configPath, original, { mode: 0o600 });
    assert.throws(
      () => configureGhcrAuth(
        'disable',
        files.dockerDirectory,
        files.configPath,
        uid,
        gid,
        { afterTemporarySync: () => { throw new Error('injected crash'); } },
      ),
      /injected crash/,
    );
    assert.equal(fs.readFileSync(files.configPath, 'utf8'), original);
    assertNoTemporaryFiles(files);
  } finally {
    cleanup(files.root);
  }
});

test('a real SIGKILL leaves one temporary file that the next transaction safely removes', async () => {
  const files = fixture();
  let child;
  try {
    const original = {
      auths: { 'ghcr.io': { auth: 'legacy-survives-disable' } },
      credHelpers: { 'ghcr.io': 'codex-ghcr' },
      currentContext: 'preserved',
    };
    writeConfig(files, original);
    const modulePath = path.join(__dirname, 'ghcr-auth-config.js');
    const childSource = `
      const { configureGhcrAuth } = require(${JSON.stringify(modulePath)});
      const [directory, config, uidValue, gidValue] = process.argv.slice(1);
      configureGhcrAuth(
        'disable',
        directory,
        config,
        Number(uidValue),
        Number(gidValue),
        {
          afterTemporarySync: () => {
            process.stdout.write('READY\\n');
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
          },
        },
      );
    `;
    child = spawn(
      process.execPath,
      ['-e', childSource, files.dockerDirectory, files.configPath, String(uid), String(gid)],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    let stdout = '';
    const ready = new Promise((resolve) => {
      child.stdout.on('data', (chunk) => {
        stdout += chunk.toString('ascii');
        if (stdout.includes('READY\n')) resolve();
      });
    });
    let readyTimer;
    try {
      await Promise.race([
        ready,
        new Promise((_, reject) => {
          readyTimer = setTimeout(
            () => reject(new Error('child did not reach fsync hook')),
            5000,
          );
        }),
      ]);
    } finally {
      clearTimeout(readyTimer);
    }
    const childClosed = once(child, 'close');
    child.kill('SIGKILL');
    await childClosed;
    child = undefined;

    assert.equal(
      fs.readdirSync(files.dockerDirectory)
        .filter((name) => name.startsWith('.config.json.codex-ghcr.')).length,
      1,
    );
    assert.deepEqual(readConfig(files), original);

    configureGhcrAuth('disable', files.dockerDirectory, files.configPath, uid, gid);
    assertNoTemporaryFiles(files);
    assert.deepEqual(readConfig(files), {
      auths: original.auths,
      credHelpers: {},
      currentContext: 'preserved',
    });
  } finally {
    if (child) {
      const childClosed = once(child, 'close');
      child.kill('SIGKILL');
      await childClosed.catch(() => {});
    }
    cleanup(files.root);
  }
});

test('stale temporary cleanup rejects symlinks and hardlinks without deleting evidence', () => {
  const files = fixture();
  const staleName = '.config.json.codex-ghcr.00000000-0000-4000-8000-000000000000';
  const stalePath = path.join(files.dockerDirectory, staleName);
  try {
    writeConfig(files, { credHelpers: { 'ghcr.io': 'codex-ghcr' } });
    fs.symlinkSync('config.json', stalePath);
    assert.throws(
      () => configureGhcrAuth('disable', files.dockerDirectory, files.configPath, uid, gid),
      /temporary file is unsafe/,
    );
    assert.equal(fs.lstatSync(stalePath).isSymbolicLink(), true);
    fs.unlinkSync(stalePath);

    fs.writeFileSync(stalePath, '{"auths":{"ghcr.io":{"auth":"legacy"}}}\n', { mode: 0o600 });
    const sibling = path.join(files.dockerDirectory, 'stale-hardlink-evidence');
    fs.linkSync(stalePath, sibling);
    assert.throws(
      () => configureGhcrAuth('disable', files.dockerDirectory, files.configPath, uid, gid),
      /temporary file is unsafe/,
    );
    assert.equal(fs.existsSync(stalePath), true);
    assert.equal(fs.existsSync(sibling), true);
  } finally {
    cleanup(files.root);
  }
});

test('pure transforms and config reader reject invalid state without mutation', () => {
  assert.throws(() => applyAction({ auths: [] }, 'enable'), /auths configuration/);
  assert.throws(() => applyAction({ credHelpers: [] }, 'disable'), /credHelpers configuration/);
  assert.throws(() => applyAction({}, 'unknown'), /action is invalid/);
  const missing = readDockerConfig('/definitely/missing/config.json', uid, gid);
  assert.deepEqual(missing, { config: {}, exists: false, identity: null, mode: null });
});
