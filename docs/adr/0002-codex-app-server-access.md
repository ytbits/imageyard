# ADR 0002: Direct access to the existing Codex daemon

- Status: Proposed revision for `codex-0.162.1-r2`
- Date: 2026-10-10

## Context

Cluster applications need to create and continue Codex threads without SSH. Desktop already uses each Devbox's managed Unix-socket App Server. The initial `r1` implementation added TLS, a bearer token and credential lifecycle management. The owner explicitly requested a simpler single-user, trusted-network interface without those requirements or a new Kubernetes Service.

## Decision

Keep default startup unchanged. When explicitly enabled, run a small Node HTTP/WebSocket relay as `codex` on port `8787`, forwarding raw frames to the existing Unix socket. There is no application authentication or encryption. Network reachability grants control of the trusted Devbox environment. Preserve basic framing checks, browser Origin rejection and upstream Unix endpoint validation without requiring caller configuration.

Use `codex app-server daemon start` to bootstrap a missing managed daemon. Keep relay recovery independent of SSH and retain optional hostname-ordinal gating. Do not create another daemon for the same Home, forcibly stop a running shared daemon, or automatically replay client requests.

Connect to a specific Pod IP or its existing StatefulSet per-Pod DNS. No new Kubernetes Service, certificate, Vault credential or ingress policy is required. The headless Service name by itself is not a per-Devbox endpoint. Callers retain the originating Devbox and thread ID, and re-resolve that Devbox after Pod replacement.

## Consequences and validation

- The caller supplies one `ws://` endpoint, with no token or certificate configuration. The accepted trust assumption is that processes with network reachability may control Codex.
- Existing Tailscale SSH/preview routes, model-provider configuration, Home/Workspace mounts and Docker/GHCR inputs stay unchanged. This direct Pod route does not automatically traverse Tailscale.
- Process recovery, request correlation, clarification handling and safe reconnect behavior remain necessary for reliable use.
- Pin Codex `0.162.1`, use a new immutable image revision, and verify both native architectures through actual unauthenticated WebSocket and desktop-proxy protocol reads. No real model task is part of these tests.
- Image publication, canary activation and live acceptance remain separate delivery steps.

See [the runbook](../runbooks/codex-app-server-access.md) and [client example](../../codex-remote-devbox/examples/app-server-client/README.md).
