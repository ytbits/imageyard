# ADR 0002: Direct access to the existing Codex daemon

- Status: Proposed revision for `codex-0.162.1-r2`
- Date: 2026-10-10

## Context

Tailnet clients need to create and continue Codex threads without SSH. Desktop already uses each Devbox's managed Unix-socket App Server. The owner requested a single-user interface on one Devbox, using its existing Tailscale hostname without application tokens, TLS configuration, a new Service or business-worker integration.

## Decision

Keep default startup unchanged. When explicitly enabled, run a small Node HTTP/WebSocket relay as `codex` on port `8787`, forwarding raw frames to the existing Unix socket. There is no application authentication or encryption. Network reachability grants control of the trusted Devbox environment. Preserve basic framing checks and upstream Unix endpoint validation without caller Origin filtering or additional client configuration.

Use `codex app-server daemon start` to bootstrap a missing managed daemon. Keep relay recovery independent of SSH and retain optional hostname-ordinal gating. Do not create another daemon for the same Home, forcibly stop a running shared daemon, or automatically replay client requests.

Expose `8787` through the existing Tailscale-annotated Service that selects only `codex-devbox-2`. Tailnet callers use `ws://codex-devbox-2:8787/`; cluster callers can use that Service's Kubernetes DNS name. No new Service, certificate, Vault credential, caller-specific policy or worker configuration is required. Callers retain the originating Devbox and thread ID across reconnects.

## Consequences and validation

- The caller supplies one `ws://` endpoint, with no token or certificate configuration. The accepted trust assumption is that processes with network reachability may control Codex.
- Add one port to the existing Devbox 2 tailnet device while preserving SSH/preview ports, model-provider configuration, Home/Workspace mounts and Docker/GHCR inputs.
- Process recovery, request correlation, clarification handling and safe reconnect behavior remain necessary for reliable use.
- Pin Codex `0.162.1`, use a new immutable image revision, and verify both native architectures through actual unauthenticated WebSocket and desktop-proxy protocol reads. No real model task is part of these tests.
- Image publication, canary activation and live acceptance remain separate delivery steps.

See [the runbook](../runbooks/codex-app-server-access.md) and [client example](../../codex-remote-devbox/examples/app-server-client/README.md).
