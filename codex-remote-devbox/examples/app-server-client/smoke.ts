import { readFileSync } from 'node:fs';
import { AppServerClient } from './client.ts';

// This command performs initialize + thread/list only. No thread or turn is created.
let client: AppServerClient | undefined;
try {
  const url = process.env.CODEX_APP_SERVER_URL;
  const tokenFile = process.env.CODEX_APP_SERVER_TOKEN_FILE;
  if (!url || !tokenFile) throw new Error('Missing endpoint or token file.');
  client = await AppServerClient.connect({
    url,
    token: readFileSync(tokenFile, 'utf8').trim(),
    tlsServerName: process.env.CODEX_APP_SERVER_TLS_SERVER_NAME,
    ca: process.env.CODEX_APP_SERVER_CA_FILE
      ? readFileSync(process.env.CODEX_APP_SERVER_CA_FILE) : undefined,
  });
  const result = await client.request<{ data: unknown[] }>('thread/list', { limit: 1, useStateDbOnly: true });
  if (!Array.isArray(result.data)) throw new Error('Invalid thread/list response.');
  console.log('App Server TLS, authentication, initialization, and read-only RPC passed.');
} catch {
  // Neither server diagnostics, thread content, configuration, nor credentials go to logs.
  console.error('App Server smoke failed; check endpoint, certificate identity, token mount, and readiness.');
  process.exitCode = 1;
} finally { client?.close(); }
