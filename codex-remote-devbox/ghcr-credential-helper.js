#!/usr/local/bin/node
'use strict';

const fs = require('node:fs');

const GHCR_SERVER = 'ghcr.io';
const RUNTIME_DIR = '/run/codex-remote-devbox/ghcr';
const USERNAME_PATH = `${RUNTIME_DIR}/ghcr_username`;
const TOKEN_PATH = `${RUNTIME_DIR}/ghcr_pat`;
const MAX_INPUT_BYTES = 4096;

function validateRuntimeDirectory(runtimeDir, uid, gid) {
  const stat = fs.lstatSync(runtimeDir);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid ||
      stat.gid !== gid || (stat.mode & 0o777) !== 0o700) {
    throw new Error('GHCR runtime directory is invalid');
  }
}

function runtimeIdentity(stat) {
  return {
    ctimeMs: stat.ctimeMs,
    dev: stat.dev,
    gid: stat.gid,
    ino: stat.ino,
    mode: stat.mode & 0o777,
    mtimeMs: stat.mtimeMs,
    nlink: stat.nlink,
    size: stat.size,
    uid: stat.uid,
  };
}

function sameRuntimeIdentity(left, right) {
  return left.ctimeMs === right.ctimeMs && left.dev === right.dev &&
    left.gid === right.gid && left.ino === right.ino && left.mode === right.mode &&
    left.mtimeMs === right.mtimeMs && left.nlink === right.nlink &&
    left.size === right.size && left.uid === right.uid;
}

function readRuntimeScalar(
  filePath,
  uid,
  gid,
  minimumLength,
  maximumLength,
  pattern,
  hooks = {},
) {
  const initial = fs.lstatSync(filePath);
  if (!initial.isFile() || initial.isSymbolicLink() || initial.uid !== uid ||
      initial.gid !== gid || (initial.mode & 0o777) !== 0o600 ||
      initial.nlink !== 1 || initial.size < minimumLength || initial.size > maximumLength) {
    throw new Error('GHCR runtime credential file is invalid');
  }

  const descriptor = fs.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || !sameRuntimeIdentity(runtimeIdentity(opened), runtimeIdentity(initial)) ||
        opened.uid !== uid || opened.gid !== gid ||
        opened.nlink !== 1 || (opened.mode & 0o777) !== 0o600) {
      throw new Error('GHCR runtime credential file changed during validation');
    }
    if (hooks.afterOpen) {
      hooks.afterOpen(filePath, descriptor);
    }
    const raw = fs.readFileSync(descriptor);
    if (hooks.afterRead) {
      hooks.afterRead(filePath, descriptor);
    }
    const afterRead = fs.fstatSync(descriptor);
    if (!afterRead.isFile() ||
        !sameRuntimeIdentity(runtimeIdentity(afterRead), runtimeIdentity(opened)) ||
        raw.length !== opened.size || raw.length < minimumLength ||
        raw.length > maximumLength || raw.some((byte) => byte > 0x7f)) {
      throw new Error('GHCR runtime credential value is invalid');
    }
    const value = raw.toString('ascii');
    if (!pattern.test(value)) {
      throw new Error('GHCR runtime credential value is invalid');
    }
    return value;
  } finally {
    fs.closeSync(descriptor);
  }
}

function loadCredential(runtimeDir = RUNTIME_DIR, uid = 1000, gid = 1000) {
  validateRuntimeDirectory(runtimeDir, uid, gid);
  const username = readRuntimeScalar(
    `${runtimeDir}/ghcr_username`,
    uid,
    gid,
    1,
    39,
    /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/,
  );
  const secret = readRuntimeScalar(
    `${runtimeDir}/ghcr_pat`,
    uid,
    gid,
    20,
    512,
    /^[!-~]+$/,
  );
  return { secret, username };
}

function normalizeServerInput(input) {
  const server = input.replace(/\r?\n$/, '');
  if (server.includes('\n') || server.includes('\r')) {
    throw new Error('credential server input is invalid');
  }
  if (![GHCR_SERVER, 'https://ghcr.io/v1', 'https://ghcr.io/v1/'].includes(server)) {
    throw new Error('credential server is unsupported');
  }
  return GHCR_SERVER;
}

function handleCommand(command, input, runtimeDir = RUNTIME_DIR, uid = 1000, gid = 1000) {
  if (Buffer.byteLength(input, 'utf8') > MAX_INPUT_BYTES) {
    throw new Error('credential helper input is too large');
  }
  switch (command) {
    case 'get': {
      normalizeServerInput(input);
      const credential = loadCredential(runtimeDir, uid, gid);
      return `${JSON.stringify({ Username: credential.username, Secret: credential.secret })}\n`;
    }
    case 'list': {
      if (input.length !== 0) {
        throw new Error('credential helper list input is invalid');
      }
      const credential = loadCredential(runtimeDir, uid, gid);
      return `${JSON.stringify({ [GHCR_SERVER]: credential.username })}\n`;
    }
    case 'store':
    case 'erase':
      throw new Error('GHCR credentials are managed by the runtime');
    default:
      throw new Error('credential helper command is unsupported');
  }
}

function readStdin() {
  const chunks = [];
  let size = 0;
  while (true) {
    const chunk = Buffer.allocUnsafe(Math.min(1024, MAX_INPUT_BYTES + 1 - size));
    const bytesRead = fs.readSync(0, chunk, 0, chunk.length, null);
    if (bytesRead === 0) {
      break;
    }
    size += bytesRead;
    if (size > MAX_INPUT_BYTES) {
      throw new Error('credential helper input is too large');
    }
    chunks.push(chunk.subarray(0, bytesRead));
  }
  return Buffer.concat(chunks).toString('utf8');
}

if (require.main === module) {
  try {
    if (process.argv.length !== 3 || process.getuid() !== 1000 || process.getgid() !== 1000) {
      throw new Error('credential helper invocation is invalid');
    }
    const input = readStdin();
    process.stdout.write(handleCommand(process.argv[2], input));
  } catch {
    process.stderr.write('docker-credential-codex-ghcr: credential operation failed\n');
    process.exitCode = 1;
  }
}

module.exports = {
  GHCR_SERVER,
  RUNTIME_DIR,
  TOKEN_PATH,
  USERNAME_PATH,
  handleCommand,
  loadCredential,
  normalizeServerInput,
  readRuntimeScalar,
  runtimeIdentity,
  sameRuntimeIdentity,
  validateRuntimeDirectory,
};
