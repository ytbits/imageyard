#!/usr/local/bin/node
'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const net = require('node:net');

if (process.argv.length !== 2) {
  throw new Error('the client smoke does not accept command-line configuration');
}
assert.match(
  process.env.DOCKER_HOST || '',
  /^unix:\/\/\/run\/codex-remote-devbox\/docker-bridge\/docker\.sock$/,
);
assert.equal(process.env.TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE, '/var/run/docker.sock');
assert.ok(process.env.TESTCONTAINERS_HOST_OVERRIDE);
assert.equal('DOCKER_CONTEXT' in process.env, false);
assert.equal('DOCKER_TLS_VERIFY' in process.env, false);
assert.equal('DOCKER_CERT_PATH' in process.env, false);
const socketPath = process.env.DOCKER_HOST.slice('unix://'.length);

function request(pathname) {
  return new Promise((resolve, reject) => {
    const request = http.request({ method: 'GET', path: pathname, socketPath }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        body: Buffer.concat(chunks),
        statusCode: response.statusCode,
      }));
    });
    request.on('error', reject);
    request.end();
  });
}

function upgraded(pathname, payload) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath, allowHalfOpen: true });
    const chunks = [];
    socket.on('connect', () => {
      socket.end(Buffer.concat([
        Buffer.from(`POST ${pathname} HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n`),
        payload,
      ]));
    });
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('end', () => {
      socket.destroy();
      resolve(Buffer.concat(chunks));
    });
    socket.on('error', reject);
  });
}

function abortLargeResponse() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    socket.on('connect', () => {
      socket.write('GET /large HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n');
    });
    socket.once('data', () => {
      socket.destroy();
      resolve();
    });
    socket.on('error', reject);
  });
}

async function main() {
  const pings = await Promise.all(Array.from({ length: 6 }, () => request('/_ping')));
  for (const ping of pings) {
    assert.equal(ping.statusCode, 200);
    assert.equal(ping.body.toString('ascii'), 'OK');
  }

  const version = await request('/version');
  assert.equal(version.statusCode, 200);
  assert.equal(JSON.parse(version.body.toString('utf8')).ApiVersion, '1.52');

  const info = await request('/info');
  assert.equal(info.statusCode, 200);
  const daemonId = JSON.parse(info.body.toString('utf8')).ID;
  assert.equal(daemonId, 'IMAGEYARD-R4-FAKE-DAEMON-ID');

  const binary = Buffer.from([0, 1, 2, 10, 13, 127, 128, 255]);
  const hijack = await upgraded('/hijack', binary);
  const separator = hijack.indexOf(Buffer.from('\r\n\r\n'));
  assert.notEqual(separator, -1);
  assert.match(hijack.subarray(0, separator).toString('ascii'), /^HTTP\/1\.1 101 /);
  assert.deepEqual(hijack.subarray(separator + 4), binary);

  const halfClose = await upgraded('/half-close', binary);
  const halfSeparator = halfClose.indexOf(Buffer.from('\r\n\r\n'));
  assert.notEqual(halfSeparator, -1);
  assert.deepEqual(
    halfClose.subarray(halfSeparator + 4),
    Buffer.concat([Buffer.from('HALF-CLOSE:'), binary]),
  );

  await abortLargeResponse();
  const pingAfterAbort = await request('/_ping');
  assert.equal(pingAfterAbort.statusCode, 200);
  assert.equal(pingAfterAbort.body.toString('ascii'), 'OK');

  process.stdout.write(`docker-bridge-client-smoke: ok ${daemonId}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
