import assert from 'node:assert/strict';
import { AppServerClient } from './client.ts';

// Explicit test-only command for an isolated unauthenticated container fixture.
// Runs two initialized clients together, reconnects, and reads config/thread lists.
// It never starts a thread or a model turn and never prints server values.
const clients: AppServerClient[] = [];
try {
  const url = process.env.CODEX_APP_SERVER_URL;
  if (!url) throw new Error('Endpoint required.');
  const options = { url };
  clients.push(await AppServerClient.connect(options));
  clients.push(await AppServerClient.connect(options));
  for (const client of clients) {
    const result = await client.request('config/read', { includeLayers: false });
    assert.ok(result.config && typeof result.config === 'object');
    const listing = await client.request('thread/list', { limit: 1, useStateDbOnly: true });
    assert.ok(Array.isArray(listing.data));
  }
  clients[0].close();
  const reconnect = await AppServerClient.connect(options);
  clients.push(reconnect);
  assert.ok(Array.isArray((await reconnect.request('thread/list', { limit: 1, useStateDbOnly: true })).data));
  // The sibling connection remains usable after one client leaves/reconnects.
  assert.ok(Array.isArray((await clients[1].request('thread/list', { limit: 1, useStateDbOnly: true })).data));
  console.log('App Server concurrent clients, read-only RPCs, and reconnect passed.');
} catch {
  console.error('App Server integration smoke failed.');
  process.exitCode = 1;
} finally { for (const client of clients) client.close(); }
