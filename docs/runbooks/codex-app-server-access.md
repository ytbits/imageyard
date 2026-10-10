# Optional Codex App Server network access

This is an opt-in runtime feature of the proposed `codex-0.162.1-r1` image. Its presence in a PR is not publication or deployment evidence. Default containers keep their existing SSH-only startup.

## Runtime inputs

| Setting | Meaning |
| --- | --- |
| `CODEX_APP_SERVER_ENABLED=1` | Enable the optional daemon manager and WSS gateway. Omit to keep it off. |
| `CODEX_APP_SERVER_ORDINAL=2` | Optional restriction to hostname `codex-devbox-2`. Other ordinals stay off. |
| `CODEX_APP_SERVER_TOKEN_FILE` | Source token, default `/run/secrets/app-server/token`. |
| `CODEX_APP_SERVER_TLS_CERT_FILE` | PEM certificate chain, default `/run/secrets/app-server/tls.crt`. |
| `CODEX_APP_SERVER_TLS_KEY_FILE` | PEM private key, default `/run/secrets/app-server/tls.key`. |

Supply a distinct high-entropy access token, not a Codex login or model-provider credential. Mount root-owned read-only files; use mode `0400` for the token/key. Kubernetes projected Secret symlinks are supported when they resolve inside the source directory to safe root-owned files. The supervisor stages private UID/GID `1000` copies under `/run/codex-remote-devbox/app-server`; it never persists them in Home/Workspace or prints them.

The gateway listens on TLS port `8443`, accepts WebSocket upgrades at `/` with `Authorization: Bearer ...`, and forwards to `/home/codex/.codex/app-server-control/app-server-control.sock`. The managed daemon may make that path a symlink to its protected per-user temporary directory. A successful upgrade preserves the original bidirectional JSON-RPC stream. Browser Origin requests are rejected.

## Startup, health and rotation

The supervisor starts the optional worker independently of SSH. When the daemon is unavailable, the worker calls its official idempotent start command as `codex`, with bounded attempts and backoff. A bad token/certificate bundle fails the gateway closed; it must not block SSH. A gateway restart does not intentionally stop the shared daemon or cancel its threads.

`GET /livez` checks the gateway process. `GET /readyz` verifies that the Unix daemon accepts a WebSocket handshake. Neither endpoint reads credentials or invokes a model. A successful health check is not proof that inference authentication or a particular project is ready. Do not make gateway readiness remove the whole Devbox from its existing SSH Service.

The supervisor checks source files every five seconds. Changed material restarts only the gateway worker with fresh private copies; deleted or unsafe material stops that worker until valid credentials return. Reconnect clients after token/certificate rotation. Existing WebSockets close during a gateway restart; read thread state after reconnect before retrying a potentially accepted operation. A full container replacement also interrupts daemon execution; persistent sessions survive only to their saved checkpoint.

## Client and network deployment

Use the [standalone TypeScript example](../../codex-remote-devbox/examples/app-server-client/README.md). Initialize each connection once, then start/resume the required thread and read notifications and server requests. Clarification and approval requests need an explicit application handler; the example does not automatically grant approval.

A cluster-only deployment can connect to `wss://codex-app-server-2.codex-devbox.svc:8443` with TLS `servername` set to the certificate's internal domain, such as `codex-app-server-2.internal.rewardsentry.com`. Hostname and trust verification remain enabled. This avoids publishing the service or changing public DNS. Mount the token in the caller and restrict network access separately. Do not add this port to an existing Tailscale-exposed Service unintentionally.

Persist `devbox/endpoint + threadId`. Reconnect and resume on the same Devbox; never randomly distribute an existing thread among independent Homes. Do not automatically replay mutating RPCs after timeout/disconnection. The protocol reports turn completion, not business-level research acceptance.

## Validation and rollout boundary

Run static/unit/client tests plus the complete disposable container smoke on native arm64 and amd64. The gateway fixture uses generated local TLS/token material, a real unauthenticated Codex daemon and protocol reads; no model request is required. Check simultaneous Unix/Desktop-compatible and network access, invalid credentials, reconnect, daemon termination/recovery, gateway termination/recovery, ordinal mismatch and disabled behavior. Preserve all existing SSH/Docker/GHCR/state tests.

For a live canary, first publish the separately approved immutable image, record its registry index digest, provision its runtime token/certificate and render the k3s-gitops canary with that exact reference. Review the render before enabling one ordinal. Live model/session acceptance and Desktop UI confirmation occur only after deployment approval; local protocol tests are not evidence of either.
