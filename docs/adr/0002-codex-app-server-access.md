# ADR 0002: Optional network access to the existing Codex daemon

- Status: Proposed
- Date: 2026-10-10

## Context

Cluster applications need to create and continue Codex threads without SSH. Desktop already uses each Devbox's managed Unix-socket App Server. Starting another server against the same Home would add competing process ownership and different in-memory thread state. The previous image deliberately started no App Server; this decision introduces an explicit opt-in exception.

## Decision

Keep default startup unchanged. When enabled, run a small Node HTTPS reverse proxy as `codex` that forwards authenticated WebSocket connections to the existing Unix socket without interpreting JSON-RPC. Require TLS and a distinct bearer token supplied through runtime files. Reject browser Origin headers and never forward the access token upstream.

The optional worker probes the actual upstream WebSocket handshake and uses `codex app-server daemon start` to start a missing daemon. It does not stop an existing daemon or replay client requests. The image supervisor restarts this worker independently of SSH; failure must not create an SSH/readiness dependency loop. Container termination still ends the entire container's processes.

Gate canary enablement by hostname ordinal. Keep routing per Devbox: callers retain both endpoint and thread ID. Thread continuation is not an interchangeable, stateless load-balancing operation. A dropped connection has an unknown request outcome until the caller reads state; it is not permission to retry `turn/start` automatically.

Read token/TLS sources at worker launch and stage private copies only under `/run`. The supervisor polls source material every five seconds, stops the worker on revocation or unsafe files, and restarts it after valid changes; callers reconnect. This is trusted single-user remote execution, with the same filesystem authority as the `codex` user, not a per-project authorization service.

## Consequences and validation

- CLIProxyAPI, account routing, Desktop SSH credentials and state mount identities stay unchanged. Codex manages its own daemon package and session files in Home; the image adds no custom migration of existing user data.
- The optional gateway is an additional supervised process and secret/certificate lifecycle to maintain. SSH remains available if it fails.
- Fixed-version client/protocol tests are required because App Server transport is experimental.
- Disposable validation covers the actual upgraded binary through WSS and SSH-compatible Unix transport, token rejection, TLS validation, concurrent clients, reconnect, daemon/gateway recovery, ordinal gating and disabled defaults. No real inference credentials or research runs are used.
- Kubernetes Services, network rules, TLS names and canary rollout belong in k3s-gitops. Image publication and live rollout are separate approval steps.

See [the operations runbook](../runbooks/codex-app-server-access.md) and [OpenAI App Server documentation](https://learn.chatgpt.com/docs/app-server).
