#!/usr/local/bin/node
'use strict';

const childProcess = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { SOCKET_DIR, SOCKET_PATH, validateRemoteSocketPath } = require('./docker-bridge.js');

const NODE_PATH = '/usr/local/bin/node';
const BRIDGE_PATH = '/usr/local/libexec/docker-bridge.js';
const SETPRIV_PATH = '/usr/bin/setpriv';
const SSHD_PATH = '/usr/sbin/sshd';
const SSHD_CONFIG = '/run/codex-remote-devbox/sshd_config';
const SERVICE_TERM_GRACE_MS = 5000;
const BRIDGE_READY_TIMEOUT_MS = 5000;

function minimalEnvironment(home, user) {
  return {
    HOME: home,
    LANG: 'C.UTF-8',
    LOGNAME: user,
    PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    SHELL: '/bin/bash',
    USER: user,
  };
}

function prepareRuntimeDirectory(socketDir = SOCKET_DIR, uid = 1000, gid = 1000) {
  const parent = fs.lstatSync(path.dirname(socketDir));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== 0 ||
      parent.gid !== 0 || (parent.mode & 0o777) !== 0o755) {
    throw new Error('bridge runtime parent directory is invalid');
  }
  try {
    const stat = fs.lstatSync(socketDir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('bridge runtime path is invalid');
    }
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
    fs.mkdirSync(socketDir, { mode: 0o700 });
  }
  fs.chownSync(socketDir, uid, gid);
  fs.chmodSync(socketDir, 0o700);
  const stat = fs.lstatSync(socketDir);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid ||
      stat.gid !== gid || (stat.mode & 0o777) !== 0o700) {
    throw new Error('bridge runtime directory metadata is invalid');
  }
  for (const entry of fs.readdirSync(socketDir)) {
    if (entry !== path.basename(SOCKET_PATH)) {
      throw new Error('bridge runtime directory contains an unexpected object');
    }
  }
}

async function socketIsLive(socketPath) {
  if (process.platform === 'linux') {
    const unixTable = fs.readFileSync('/proc/net/unix', 'utf8');
    return unixTable.split('\n').some((line) => {
      const fields = line.trim().split(/\s+/);
      return fields.length >= 8 && fields.slice(7).join(' ') === socketPath;
    });
  }
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('bridge socket liveness probe timed out'));
    }, 500);
    socket.once('connect', () => {
      clearTimeout(timer);
      socket.destroy();
      resolve(true);
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      socket.destroy();
      if (error.code === 'ECONNREFUSED' || error.code === 'ENOENT') {
        resolve(false);
      } else {
        reject(error);
      }
    });
  });
}

async function removeStaleSocket(socketPath = SOCKET_PATH, uid = 1000, gid = 1000) {
  let stat;
  try {
    stat = fs.lstatSync(socketPath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return;
    }
    throw error;
  }
  if (!stat.isSocket() || stat.isSymbolicLink()) {
    throw new Error('bridge socket path is occupied by an unsafe object');
  }
  if (stat.uid !== uid || stat.gid !== gid || (stat.mode & 0o777) !== 0o600) {
    throw new Error('bridge stale socket metadata is invalid');
  }
  if (await socketIsLive(socketPath)) {
    throw new Error('bridge socket is already live');
  }
  const current = fs.lstatSync(socketPath);
  if (!current.isSocket() || current.isSymbolicLink() ||
      current.uid !== uid || current.gid !== gid ||
      (current.mode & 0o777) !== 0o600 ||
      current.dev !== stat.dev || current.ino !== stat.ino) {
    throw new Error('bridge socket changed during stale cleanup');
  }
  fs.unlinkSync(socketPath);
}

function validateReadySocket(socketDir = SOCKET_DIR, socketPath = SOCKET_PATH, uid = 1000, gid = 1000) {
  const directory = fs.lstatSync(socketDir);
  const socket = fs.lstatSync(socketPath);
  if (!directory.isDirectory() || directory.isSymbolicLink() ||
      directory.uid !== uid || directory.gid !== gid ||
      (directory.mode & 0o777) !== 0o700) {
    throw new Error('bridge runtime directory is not ready');
  }
  if (!socket.isSocket() || socket.isSymbolicLink() || socket.uid !== uid ||
      socket.gid !== gid || (socket.mode & 0o777) !== 0o600) {
    throw new Error('bridge socket is not ready');
  }
  return { dev: socket.dev, ino: socket.ino };
}

function signalChild(child, signal) {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  try {
    child.kill(signal);
  } catch {
    // The child may have exited between checks.
  }
}

function closePromise(child) {
  return child ? new Promise((resolve) => child.once('close', resolve)) : Promise.resolve();
}

async function waitWithTimeout(promise, timeoutMs) {
  let timer;
  try {
    return await Promise.race([
      promise.then(() => true),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(false), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function validateRootFile(filePath, executable = false) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== 0 || stat.gid !== 0 ||
      (stat.mode & 0o022) !== 0 || (executable && (stat.mode & 0o111) === 0)) {
    throw new Error('required supervisor file is unsafe');
  }
}

function bridgeLaunch(remoteSocketPath) {
  const validatedPath = validateRemoteSocketPath(remoteSocketPath);
  return {
    command: SETPRIV_PATH,
    args: [
      '--reuid=1000',
      '--regid=1000',
      '--clear-groups',
      '--no-new-privs',
      '--',
      NODE_PATH,
      BRIDGE_PATH,
      validatedPath,
    ],
    options: {
      detached: false,
      env: minimalEnvironment('/home/codex', 'codex'),
      stdio: ['ignore', 'ignore', 'inherit', 'ipc'],
    },
  };
}

async function main() {
  if (process.argv.length !== 3 || process.getuid() !== 0 || process.getgid() !== 0) {
    throw new Error('supervisor invocation is invalid');
  }
  const remoteSocketPath = validateRemoteSocketPath(process.argv[2]);
  validateRootFile(NODE_PATH, true);
  validateRootFile(BRIDGE_PATH);
  validateRootFile(SETPRIV_PATH, true);
  validateRootFile(SSHD_PATH, true);
  validateRootFile(SSHD_CONFIG);
  prepareRuntimeDirectory();
  await removeStaleSocket();

  let bridge = null;
  let bridgeClosed = Promise.resolve();
  let sshd = null;
  let sshdClosed = Promise.resolve();
  let socketIdentity = null;
  let stopping = false;
  let shutdownPromise = null;

  const safeSocketCleanup = () => {
    if (!socketIdentity) {
      return;
    }
    try {
      const stat = fs.lstatSync(SOCKET_PATH);
      if (stat.isSocket() && !stat.isSymbolicLink() &&
          stat.dev === socketIdentity.dev && stat.ino === socketIdentity.ino) {
        fs.unlinkSync(SOCKET_PATH);
      }
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }
  };

  const shutdown = (exitCode) => {
    if (shutdownPromise) {
      return shutdownPromise;
    }
    stopping = true;
    shutdownPromise = (async () => {
      let finalExitCode = exitCode;
      signalChild(bridge, 'SIGTERM');
      signalChild(sshd, 'SIGTERM');
      const closed = Promise.all([bridgeClosed, sshdClosed]);
      await waitWithTimeout(closed, SERVICE_TERM_GRACE_MS);
      signalChild(bridge, 'SIGKILL');
      signalChild(sshd, 'SIGKILL');
      await waitWithTimeout(closed, 1000);
      try {
        safeSocketCleanup();
      } catch {
        process.stderr.write('codex-remote-devbox: Docker bridge socket cleanup failed\n');
        finalExitCode = 1;
      }
      process.exitCode = finalExitCode;
    })();
    return shutdownPromise;
  };

  process.on('SIGHUP', () => void shutdown(129));
  process.on('SIGINT', () => void shutdown(130));
  process.on('SIGTERM', () => void shutdown(143));

  const launch = bridgeLaunch(remoteSocketPath);
  bridge = childProcess.spawn(launch.command, launch.args, launch.options);
  bridgeClosed = closePromise(bridge);
  bridge.once('error', () => void shutdown(1));
  bridge.once('exit', () => {
    if (!stopping) {
      process.stderr.write('codex-remote-devbox: Docker bridge exited unexpectedly\n');
      void shutdown(1);
    }
  });

  try {
    await new Promise((resolve, reject) => {
      const onExit = () => {
        cleanup();
        reject(new Error('bridge exited before readiness'));
      };
      const onMessage = (message) => {
        if (message && message.type === 'ready') {
          cleanup();
          resolve();
        }
      };
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error('bridge readiness timed out'));
      }, BRIDGE_READY_TIMEOUT_MS);
      const cleanup = () => {
        clearTimeout(timer);
        bridge.off('message', onMessage);
        bridge.off('exit', onExit);
      };
      bridge.on('message', onMessage);
      bridge.once('exit', onExit);
    });
    socketIdentity = validateReadySocket();
  } catch {
    process.stderr.write('codex-remote-devbox: Docker bridge readiness failed\n');
    await shutdown(1);
    return;
  }

  if (stopping) {
    await shutdownPromise;
    return;
  }

  try {
    sshd = childProcess.spawn(SSHD_PATH, ['-D', '-e', '-f', SSHD_CONFIG], {
      detached: false,
      env: minimalEnvironment('/root', 'root'),
      stdio: ['ignore', 'inherit', 'inherit'],
    });
    sshdClosed = closePromise(sshd);
  } catch {
    await shutdown(1);
    return;
  }
  sshd.once('error', () => void shutdown(1));
  sshd.once('exit', () => {
    if (!stopping) {
      process.stderr.write('codex-remote-devbox: OpenSSH exited unexpectedly\n');
      void shutdown(1);
    }
  });
}

if (require.main === module) {
  main().catch(() => {
    process.stderr.write('codex-remote-devbox: service supervision failed\n');
    process.exitCode = 1;
  });
}

module.exports = {
  bridgeLaunch,
  closePromise,
  minimalEnvironment,
  prepareRuntimeDirectory,
  removeStaleSocket,
  socketIsLive,
  validateReadySocket,
  waitWithTimeout,
};
