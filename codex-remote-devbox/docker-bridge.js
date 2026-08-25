#!/usr/local/bin/node
'use strict';

const childProcess = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { EventEmitter } = require('node:events');

const SOCKET_DIR = '/run/codex-remote-devbox/docker-bridge';
const SOCKET_PATH = `${SOCKET_DIR}/docker.sock`;
const SSH_PATH = '/usr/bin/ssh';
const SOCKET_CHECK_INTERVAL_MS = 500;
const CHILD_TERM_GRACE_MS = 2000;

function sshEnvironment() {
  return {
    HOME: '/home/codex',
    LANG: 'C.UTF-8',
    LOGNAME: 'codex',
    PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    SHELL: '/bin/bash',
    USER: 'codex',
  };
}

function validateRemoteSocketPath(value) {
  if (typeof value !== 'string' || value.length < 2 || value.length > 4096) {
    throw new Error('invalid remote Docker socket path');
  }
  if (!/^\/[A-Za-z0-9._~/-]+$/.test(value) || value.includes('//') || value.endsWith('/')) {
    throw new Error('invalid remote Docker socket path');
  }
  if (value.split('/').some((segment) => segment === '.' || segment === '..')) {
    throw new Error('invalid remote Docker socket path');
  }
  return value;
}

function buildSshArgs(remoteSocketPath) {
  const validatedPath = validateRemoteSocketPath(remoteSocketPath);
  return Object.freeze([
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
    `--host=unix://${validatedPath}`,
    'system',
    'dial-stdio',
  ]);
}

function metadataMatches(stat, uid, gid, mode) {
  return stat.uid === uid && stat.gid === gid && (stat.mode & 0o777) === mode;
}

function isExpectedDisconnect(error) {
  return error && ['EPIPE', 'ECONNRESET', 'ENOTCONN', 'ERR_STREAM_DESTROYED'].includes(error.code);
}

class DockerBridge extends EventEmitter {
  constructor(options) {
    super();
    const settings = options || {};
    this.socketDir = settings.socketDir || SOCKET_DIR;
    this.socketPath = settings.socketPath || SOCKET_PATH;
    this.remoteSocketPath = validateRemoteSocketPath(settings.remoteSocketPath);
    this.sshPath = settings.sshPath || SSH_PATH;
    this.sshArgs = settings.sshArgs || buildSshArgs(this.remoteSocketPath);
    this.spawn = settings.spawn || childProcess.spawn;
    this.expectedUid = settings.expectedUid ?? process.getuid();
    this.expectedGid = settings.expectedGid ?? process.getgid();
    this.childTermGraceMs = settings.childTermGraceMs ?? CHILD_TERM_GRACE_MS;
    this.socketCheckIntervalMs = settings.socketCheckIntervalMs ?? SOCKET_CHECK_INTERVAL_MS;
    this.server = null;
    this.boundIdentity = null;
    this.connections = new Set();
    this.monitor = null;
    this.stopping = false;
    this.stopPromise = null;
    this.fatalEmitted = false;
    this.socketIdentityCompromised = false;
  }

  validateRuntimeDirectory() {
    const stat = fs.lstatSync(this.socketDir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('bridge runtime directory is invalid');
    }
    if (!metadataMatches(stat, this.expectedUid, this.expectedGid, 0o700)) {
      throw new Error('bridge runtime directory metadata is invalid');
    }
    const expectedParent = path.dirname(this.socketPath);
    if (expectedParent !== this.socketDir) {
      throw new Error('bridge socket path is outside the runtime directory');
    }
  }

  validateBoundSocket() {
    const stat = fs.lstatSync(this.socketPath);
    if (!stat.isSocket() || stat.isSymbolicLink()) {
      throw new Error('bridge socket is invalid');
    }
    if (!metadataMatches(stat, this.expectedUid, this.expectedGid, 0o600)) {
      throw new Error('bridge socket metadata is invalid');
    }
    if (this.boundIdentity &&
        (stat.dev !== this.boundIdentity.dev || stat.ino !== this.boundIdentity.ino)) {
      throw new Error('bridge socket identity changed');
    }
    return stat;
  }

  async start() {
    if (this.server) {
      throw new Error('bridge is already started');
    }
    this.validateRuntimeDirectory();
    try {
      fs.lstatSync(this.socketPath);
      throw new Error('bridge socket path already exists');
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }

    this.server = net.createServer({ allowHalfOpen: true }, (socket) => this.handleConnection(socket));
    this.server.on('error', () => {
      if (!this.stopping) {
        this.failRuntime('bridge listener failed');
      }
    });

    let listenerBound = false;
    const previousUmask = process.umask(0o177);
    try {
      await new Promise((resolve, reject) => {
        const onStartupError = (error) => reject(error);
        this.server.once('error', onStartupError);
        this.server.listen(this.socketPath, () => {
          this.server.off('error', onStartupError);
          listenerBound = true;
          resolve();
        });
      });
    } finally {
      process.umask(previousUmask);
    }

    try {
      // The restrictive umask makes the socket 0600 at bind time, avoiding a
      // chmod-by-path race. Any failure after bind is treated as an identity
      // compromise so libuv cannot unlink a replacement during cleanup.
      const stat = this.validateBoundSocket();
      this.boundIdentity = { dev: stat.dev, ino: stat.ino };
    } catch (error) {
      if (listenerBound) {
        this.socketIdentityCompromised = true;
      }
      throw error;
    }
    this.monitor = setInterval(() => {
      if (this.stopping) {
        return;
      }
      try {
        this.validateRuntimeDirectory();
        this.validateBoundSocket();
      } catch {
        // Once the pathname or its containing directory can no longer be
        // trusted, server.close() is unsafe: libuv unlinks the pathname even
        // when another object has replaced the socket. The fatal stop path
        // therefore reaps connections without closing the listener, then
        // exits explicitly so normal libuv teardown cannot close it later.
        this.socketIdentityCompromised = true;
        this.failRuntime('bridge runtime socket changed');
      }
    }, this.socketCheckIntervalMs);
  }

  failRuntime(message) {
    if (!this.stopping && !this.fatalEmitted) {
      this.fatalEmitted = true;
      this.emit('fatal', new Error(message));
    }
  }

  handleConnection(socket) {
    if (this.stopping) {
      socket.destroy();
      return;
    }
    socket.setNoDelay(true);
    let child;
    try {
      child = this.spawn(this.sshPath, this.sshArgs, {
        stdio: ['pipe', 'pipe', 'ignore'],
        shell: false,
        detached: false,
        env: sshEnvironment(),
        windowsHide: true,
      });
    } catch {
      socket.destroy();
      this.failRuntime('could not spawn SSH transport');
      return;
    }

    const state = {
      socket,
      child,
      childClosed: false,
      socketClosed: false,
      termTimer: null,
    };
    this.connections.add(state);

    const finishIfClosed = () => {
      if (state.childClosed && state.socketClosed) {
        clearTimeout(state.termTimer);
        this.connections.delete(state);
      }
    };

    const terminateChild = () => {
      if (state.childClosed || child.exitCode !== null || child.signalCode !== null) {
        return;
      }
      try {
        child.kill('SIGTERM');
      } catch {
        return;
      }
      clearTimeout(state.termTimer);
      state.termTimer = setTimeout(() => {
        if (!state.childClosed && child.exitCode === null && child.signalCode === null) {
          try {
            child.kill('SIGKILL');
          } catch {
            // The child may have exited between the state check and kill.
          }
        }
      }, this.childTermGraceMs);
    };

    child.stdin.on('error', (error) => {
      if (isExpectedDisconnect(error)) {
        socket.unpipe(child.stdin);
        socket.resume();
      } else {
        socket.destroy();
      }
    });
    child.stdout.on('error', (error) => {
      if (!isExpectedDisconnect(error)) {
        socket.destroy();
      }
    });
    socket.on('error', (error) => {
      void error;
      socket.destroy();
      terminateChild();
    });
    socket.on('close', () => {
      state.socketClosed = true;
      terminateChild();
      finishIfClosed();
    });
    child.on('error', () => {
      socket.destroy();
      this.failRuntime('SSH transport executable failed');
    });
    child.on('close', () => {
      state.childClosed = true;
      clearTimeout(state.termTimer);
      if (!socket.destroyed) {
        if (socket.writableFinished) {
          socket.destroy();
        } else {
          socket.once('finish', () => socket.destroy());
          if (!socket.writableEnded) {
            socket.end();
          }
        }
      }
      finishIfClosed();
    });

    // Keep both byte streams independent. A read-side EOF closes only the
    // corresponding write side, which is required for Docker hijack and
    // half-close semantics.
    socket.pipe(child.stdin, { end: true });
    child.stdout.pipe(socket, { end: true });
  }

  unlinkBoundSocket() {
    if (!this.boundIdentity) {
      return;
    }
    try {
      const stat = fs.lstatSync(this.socketPath);
      if (stat.isSocket() && !stat.isSymbolicLink() &&
          stat.dev === this.boundIdentity.dev && stat.ino === this.boundIdentity.ino) {
        fs.unlinkSync(this.socketPath);
      }
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }
  }

  stop() {
    if (this.stopPromise) {
      return this.stopPromise;
    }
    this.stopPromise = this.stopInternal();
    return this.stopPromise;
  }

  async stopInternal() {
    this.stopping = true;
    clearInterval(this.monitor);
    let cleanupError = null;
    if (this.server && this.boundIdentity && !this.socketIdentityCompromised) {
      try {
        // Close the monitor interval's observation window before entering
        // libuv's close path. A cross-process replacement can still race the
        // final lstat and close (there is no inode-addressed close API here),
        // but an already-compromised pathname must never be passed to close().
        this.validateRuntimeDirectory();
        this.validateBoundSocket();
      } catch {
        this.socketIdentityCompromised = true;
      }
    }
    if (this.server && this.socketIdentityCompromised) {
      // Do not call close(): for Unix listeners Node/libuv would unlink an
      // attacker-controlled replacement at the bound pathname. Unref keeps
      // the listener out of ordinary cleanup while the fatal bridge process
      // reaps its SSH children and then exits explicitly.
      this.server.unref();
    } else if (this.server) {
      try {
        this.server.close();
      } catch (error) {
        if (error.code !== 'ERR_SERVER_NOT_RUNNING') {
          cleanupError = error;
        }
      }
    }

    for (const state of this.connections) {
      state.socket.destroy();
      if (!state.childClosed && state.child.exitCode === null && state.child.signalCode === null) {
        try {
          state.child.kill('SIGTERM');
        } catch {
          // The child may already be gone.
        }
      }
    }

    const deadline = Date.now() + this.childTermGraceMs;
    while (this.connections.size > 0 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    for (const state of this.connections) {
      if (!state.childClosed && state.child.exitCode === null && state.child.signalCode === null) {
        try {
          state.child.kill('SIGKILL');
        } catch {
          // The child may already be gone.
        }
      }
      state.socket.destroy();
    }
    const killDeadline = Date.now() + 1000;
    while (this.connections.size > 0 && Date.now() < killDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    if (!this.socketIdentityCompromised) {
      try {
        this.unlinkBoundSocket();
      } catch (error) {
        cleanupError = cleanupError || error;
      }
    }
    if (cleanupError) {
      throw cleanupError;
    }
  }
}

function validateProcessIdentity(uid, gid, groups, status) {
  if (uid !== 1000 || gid !== 1000 || groups.some((group) => group !== 1000)) {
    throw new Error('bridge process identity is invalid');
  }
  if (!/^CapEff:\s+0+$/m.test(status) || !/^NoNewPrivs:\s+1$/m.test(status)) {
    throw new Error('bridge process privilege state is invalid');
  }
}

async function finishBridgeProcess(bridge, exitCode) {
  let finalExitCode = exitCode;
  try {
    await bridge.stop();
  } catch {
    finalExitCode = 1;
  }
  if (typeof process.disconnect === 'function' && process.connected) {
    process.disconnect();
  }
  if (bridge.socketIdentityCompromised) {
    // A natural Node teardown closes an unrefed Unix listener and lets libuv
    // unlink whatever currently occupies its pathname. Explicit exit bypasses
    // that unsafe cleanup after all connection children have been reaped.
    process.exit(finalExitCode === 0 ? 1 : finalExitCode);
  }
  process.exitCode = finalExitCode;
}

async function main() {
  if (process.argv.length !== 3) {
    throw new Error('bridge requires exactly one validated remote socket path');
  }
  validateProcessIdentity(
    process.getuid(),
    process.getgid(),
    process.getgroups(),
    fs.readFileSync('/proc/self/status', 'utf8'),
  );
  if (typeof process.send !== 'function' || !process.connected) {
    throw new Error('bridge requires its supervisor IPC channel');
  }

  const bridge = new DockerBridge({
    remoteSocketPath: process.argv[2],
    expectedUid: 1000,
    expectedGid: 1000,
  });
  let finishPromise = null;
  const finish = (exitCode) => {
    if (finishPromise) {
      return finishPromise;
    }
    finishPromise = finishBridgeProcess(bridge, exitCode);
    return finishPromise;
  };

  bridge.on('fatal', () => {
    process.stderr.write('codex-docker-bridge: runtime contract failed\n');
    void finish(1);
  });
  process.on('SIGHUP', () => void finish(129));
  process.on('SIGINT', () => void finish(130));
  process.on('SIGTERM', () => void finish(143));
  process.on('disconnect', () => void finish(1));
  process.on('uncaughtException', () => {
    process.stderr.write('codex-docker-bridge: uncaught runtime failure\n');
    void finish(1);
  });
  process.on('unhandledRejection', () => {
    process.stderr.write('codex-docker-bridge: unhandled runtime failure\n');
    void finish(1);
  });

  try {
    await bridge.start();
    if (!process.connected) {
      throw new Error('bridge supervisor disconnected before readiness');
    }
    process.send({ type: 'ready' });
  } catch {
    process.stderr.write('codex-docker-bridge: startup failed\n');
    await finish(1);
  }
}

if (require.main === module) {
  main().catch(() => {
    process.stderr.write('codex-docker-bridge: startup failed\n');
    process.exitCode = 1;
  });
}

module.exports = {
  CHILD_TERM_GRACE_MS,
  DockerBridge,
  SOCKET_DIR,
  SOCKET_PATH,
  SSH_PATH,
  buildSshArgs,
  finishBridgeProcess,
  validateProcessIdentity,
  validateRemoteSocketPath,
};
