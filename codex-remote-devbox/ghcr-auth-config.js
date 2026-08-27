#!/usr/local/bin/node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { TextDecoder } = require('node:util');

const DOCKER_CONFIG_DIRECTORY = '/home/codex/.docker';
const DOCKER_CONFIG_PATH = `${DOCKER_CONFIG_DIRECTORY}/config.json`;
const GHCR_HELPER = 'codex-ghcr';
const GHCR_REGISTRY = 'ghcr.io';
const MAX_CONFIG_BYTES = 1024 * 1024;
const STALE_TEMPORARY_PATTERN = /^\.config\.json\.codex-ghcr\.[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UTF8_DECODER = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const VALID_ACTIONS = new Set(['disable', 'enable', 'scrub-legacy-auth']);

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validateOwnedDirectory(directoryPath, uid, gid) {
  const stat = fs.lstatSync(directoryPath);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid || stat.gid !== gid) {
    throw new Error('Docker configuration directory is unsafe');
  }
  if ((stat.mode & 0o777) !== 0o700) {
    fs.chmodSync(directoryPath, 0o700);
  }
  const verified = fs.lstatSync(directoryPath);
  if (!verified.isDirectory() || verified.isSymbolicLink() || verified.uid !== uid ||
      verified.gid !== gid || (verified.mode & 0o777) !== 0o700) {
    throw new Error('Docker configuration directory metadata is invalid');
  }
}

function identity(stat) {
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

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino &&
    left.uid === right.uid && left.gid === right.gid && left.mode === right.mode &&
    left.size === right.size && left.mtimeMs === right.mtimeMs &&
    left.ctimeMs === right.ctimeMs && left.nlink === right.nlink;
}

function readDockerConfig(configPath, uid, gid, hooks = {}) {
  let initial;
  try {
    initial = fs.lstatSync(configPath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return { config: {}, exists: false, identity: null, mode: null };
    }
    throw error;
  }
  if (!initial.isFile() || initial.isSymbolicLink() || initial.uid !== uid ||
      initial.gid !== gid || initial.nlink !== 1 || initial.size > MAX_CONFIG_BYTES) {
    throw new Error('Docker configuration file is unsafe');
  }

  const descriptor = fs.openSync(configPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || !sameIdentity(identity(opened), identity(initial)) ||
        opened.uid !== uid || opened.gid !== gid || opened.nlink !== 1 ||
        opened.size > MAX_CONFIG_BYTES) {
      throw new Error('Docker configuration file changed during validation');
    }
    if (hooks.afterOpen) {
      hooks.afterOpen(configPath, descriptor);
    }
    const raw = fs.readFileSync(descriptor);
    if (hooks.afterRead) {
      hooks.afterRead(configPath, descriptor);
    }
    const afterRead = fs.fstatSync(descriptor);
    if (!afterRead.isFile() ||
        !sameIdentity(identity(afterRead), identity(opened)) || raw.length !== opened.size) {
      throw new Error('Docker configuration changed during read');
    }
    let decoded;
    try {
      decoded = UTF8_DECODER.decode(raw);
    } catch {
      throw new Error('Docker configuration is not valid UTF-8');
    }
    const config = JSON.parse(decoded);
    if (!isPlainObject(config)) {
      throw new Error('Docker configuration must be a JSON object');
    }
    return {
      config,
      exists: true,
      identity: identity(opened),
      mode: opened.mode & 0o777,
    };
  } finally {
    fs.closeSync(descriptor);
  }
}

function fsyncDirectory(directoryPath) {
  const descriptor = fs.openSync(directoryPath, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
  try {
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function cleanupStaleTemporaryFiles(directoryPath, uid, gid) {
  const candidates = [];
  for (const name of fs.readdirSync(directoryPath)) {
    if (!STALE_TEMPORARY_PATTERN.test(name)) {
      continue;
    }
    const temporaryPath = path.join(directoryPath, name);
    const stat = fs.lstatSync(temporaryPath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid || stat.gid !== gid ||
        stat.nlink !== 1 || (stat.mode & 0o777) !== 0o600) {
      throw new Error('stale Docker configuration temporary file is unsafe');
    }
    candidates.push({ identity: identity(stat), temporaryPath });
  }

  for (const candidate of candidates) {
    const current = fs.lstatSync(candidate.temporaryPath);
    if (!current.isFile() || current.isSymbolicLink() || current.uid !== uid ||
        current.gid !== gid || current.nlink !== 1 ||
        (current.mode & 0o777) !== 0o600 ||
        !sameIdentity(identity(current), candidate.identity)) {
      throw new Error('stale Docker configuration temporary file changed during validation');
    }
  }

  for (const candidate of candidates) {
    fs.unlinkSync(candidate.temporaryPath);
  }
  if (candidates.length > 0) {
    fsyncDirectory(directoryPath);
  }
}

function validateDockerSections(config) {
  if ('auths' in config && !isPlainObject(config.auths)) {
    throw new Error('Docker auths configuration must be a JSON object');
  }
  if ('credHelpers' in config && !isPlainObject(config.credHelpers)) {
    throw new Error('Docker credHelpers configuration must be a JSON object');
  }
}

function applyEnable(config) {
  validateDockerSections(config);
  if (!('credHelpers' in config)) {
    config.credHelpers = {};
  }
  if (config.credHelpers[GHCR_REGISTRY] === GHCR_HELPER) {
    return false;
  }
  if (GHCR_REGISTRY in config.credHelpers) {
    throw new Error('GHCR Docker helper mapping is not image-managed');
  }
  config.credHelpers[GHCR_REGISTRY] = GHCR_HELPER;
  return true;
}

function applyDisable(config) {
  validateDockerSections(config);
  if (!('credHelpers' in config) || !(GHCR_REGISTRY in config.credHelpers)) {
    return false;
  }
  if (config.credHelpers[GHCR_REGISTRY] !== GHCR_HELPER) {
    throw new Error('GHCR Docker helper mapping is not image-managed');
  }
  delete config.credHelpers[GHCR_REGISTRY];
  return true;
}

function applyLegacyAuthScrub(config) {
  validateDockerSections(config);
  if (!('auths' in config) || !(GHCR_REGISTRY in config.auths)) {
    return false;
  }
  delete config.auths[GHCR_REGISTRY];
  return true;
}

function applyAction(config, action) {
  switch (action) {
    case 'enable':
      return applyEnable(config);
    case 'disable':
      return applyDisable(config);
    case 'scrub-legacy-auth':
      return applyLegacyAuthScrub(config);
    default:
      throw new Error('GHCR Docker configuration action is invalid');
  }
}

function verifyTargetUnchanged(configPath, expectedState) {
  let current;
  try {
    current = fs.lstatSync(configPath);
  } catch (error) {
    if (error.code === 'ENOENT' && !expectedState.exists) {
      return;
    }
    throw new Error('Docker configuration changed concurrently');
  }
  if (!expectedState.exists || !current.isFile() || current.isSymbolicLink() ||
      current.nlink !== 1 || !sameIdentity(identity(current), expectedState.identity)) {
    throw new Error('Docker configuration changed concurrently');
  }
}

function atomicWriteConfig(configPath, config, uid, gid, expectedState, hooks = {}) {
  const directoryPath = path.dirname(configPath);
  const temporaryPath = path.join(directoryPath, `.config.json.codex-ghcr.${randomUUID()}`);
  let descriptor;
  try {
    descriptor = fs.openSync(
      temporaryPath,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
      0o600,
    );
    fs.writeFileSync(descriptor, `${JSON.stringify(config, null, 2)}\n`, 'utf8');
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    const temporaryStat = fs.lstatSync(temporaryPath);
    if (!temporaryStat.isFile() || temporaryStat.isSymbolicLink() ||
        temporaryStat.uid !== uid || temporaryStat.gid !== gid ||
        temporaryStat.nlink !== 1 || (temporaryStat.mode & 0o777) !== 0o600) {
      throw new Error('temporary Docker configuration metadata is invalid');
    }
    if (hooks.afterTemporarySync) {
      hooks.afterTemporarySync(temporaryPath);
    }
    verifyTargetUnchanged(configPath, expectedState);
    fs.renameSync(temporaryPath, configPath);
    fsyncDirectory(directoryPath);
  } finally {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
    try {
      fs.unlinkSync(temporaryPath);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }
  }
}

function configureGhcrAuth(
  action,
  configDirectory = DOCKER_CONFIG_DIRECTORY,
  configPath = DOCKER_CONFIG_PATH,
  uid = 1000,
  gid = 1000,
  hooks = {},
) {
  if (!VALID_ACTIONS.has(action) || process.getuid() !== uid || process.getgid() !== gid) {
    throw new Error('GHCR Docker configuration invocation is invalid');
  }
  try {
    fs.mkdirSync(configDirectory, { mode: 0o700 });
  } catch (error) {
    if (error.code !== 'EEXIST') {
      throw error;
    }
  }
  validateOwnedDirectory(configDirectory, uid, gid);
  cleanupStaleTemporaryFiles(configDirectory, uid, gid);
  const state = readDockerConfig(configPath, uid, gid);
  const changed = applyAction(state.config, action);
  if (!changed && (!state.exists || state.mode === 0o600)) {
    return;
  }
  atomicWriteConfig(configPath, state.config, uid, gid, state, hooks);
  const verified = fs.lstatSync(configPath);
  if (!verified.isFile() || verified.isSymbolicLink() || verified.uid !== uid ||
      verified.gid !== gid || verified.nlink !== 1 ||
      (verified.mode & 0o777) !== 0o600) {
    throw new Error('Docker configuration file metadata is invalid');
  }
}

if (require.main === module) {
  try {
    if (process.argv.length !== 3) {
      throw new Error('GHCR Docker configuration invocation is invalid');
    }
    configureGhcrAuth(process.argv[2]);
  } catch {
    process.stderr.write('codex-remote-devbox: GHCR Docker configuration failed\n');
    process.exitCode = 1;
  }
}

module.exports = {
  DOCKER_CONFIG_DIRECTORY,
  DOCKER_CONFIG_PATH,
  GHCR_HELPER,
  GHCR_REGISTRY,
  applyAction,
  applyDisable,
  applyEnable,
  applyLegacyAuthScrub,
  atomicWriteConfig,
  cleanupStaleTemporaryFiles,
  configureGhcrAuth,
  fsyncDirectory,
  identity,
  isPlainObject,
  readDockerConfig,
  sameIdentity,
  validateDockerSections,
  validateOwnedDirectory,
  verifyTargetUnchanged,
};
