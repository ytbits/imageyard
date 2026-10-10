import { AppServerClient } from './client.ts';

// This command performs initialize + thread/list only. No thread or turn is created.
let client: AppServerClient | undefined;
try {
  const url = process.env.CODEX_APP_SERVER_URL;
  if (!url) throw new Error('Missing endpoint.');
  client = await AppServerClient.connect({ url });
  const result = await client.request<{ data: unknown[] }>('thread/list', { limit: 1, useStateDbOnly: true });
  if (!Array.isArray(result.data)) throw new Error('Invalid thread/list response.');
  console.log('App Server connection, initialization, and read-only RPC passed.');
} catch {
  // Neither server diagnostics, thread content, nor configuration go to logs.
  console.error('App Server smoke failed; check the Devbox endpoint and readiness.');
  process.exitCode = 1;
} finally { client?.close(); }
