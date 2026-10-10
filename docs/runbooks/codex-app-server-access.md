# Direct Codex App Server access

The proposed `codex-0.162.1-r2` image provides an opt-in plain WebSocket relay to the existing managed daemon. Default containers keep SSH-only startup. This review candidate is not publication or deployment evidence.

## Start and connect

Only two runtime settings exist:

| Setting | Meaning |
| --- | --- |
| `CODEX_APP_SERVER_ENABLED=1` | Start the relay and ensure the managed daemon is running. Omit to keep it off. |
| `CODEX_APP_SERVER_ORDINAL=2` | Optional restriction to hostname `codex-devbox-2`. Other ordinals stay off. |

The relay listens on `0.0.0.0:8787`, accepts WebSocket upgrades at `/`, and forwards raw frames to `/home/codex/.codex/app-server-control/app-server-control.sock`. There is no App Server token, TLS certificate, Secret mount, dedicated hostname certificate, or credential rotation. Any process able to reach the port can control this trusted Codex environment. Valid WebSocket requests are accepted without a caller identity or Origin filter.

The one-Devbox canary adds port `8787` to the existing Tailscale-exposed `codex-devbox-2` Service. After activation, a tailnet client uses:

```text
ws://codex-devbox-2:8787/
```

Use the device's full MagicDNS name when the short name is unavailable. The existing Service selects only Devbox 2, so connections always return to the same Devbox. The Tailscale operator reuses its existing tailnet device; no new Service or caller-specific access rules are added. See [Tailscale cluster ingress](https://tailscale.com/docs/kubernetes-operator/ingress).

Cluster callers can use `ws://codex-devbox-2.codex-devbox.svc:8787/` for the same single-Devbox endpoint. Existing SSH/preview ports remain available. Business-worker integration is outside this change.

Use the [TypeScript client](../../codex-remote-devbox/examples/app-server-client/README.md). Supply only `CODEX_APP_SERVER_URL` for the read-only smoke command. Initialize each connection once, then start or resume a thread on the selected Devbox. Persist `devbox identity/endpoint + threadId`; reconnect to the same ordinal and reconcile state before retrying an uncertain operation. Clarification/approval handlers and task acceptance belong to the calling application.

## Lifecycle

The optional worker uses `codex app-server daemon start` when the Unix daemon is unavailable. The official command owns daemon identity and locking. Relay recovery is independent of SSH; restarting the relay does not intentionally stop the shared daemon. An unresponsive but still-running daemon is surfaced as unavailable rather than forcibly killed. The daemon receives the same image-owned Docker/Testcontainers environment as SSH sessions.

`GET /livez` checks the relay process. `GET /readyz` verifies that the Unix daemon accepts a WebSocket handshake. Neither invokes a model; readiness does not prove inference authentication or project readiness. Do not couple these checks to whole-Pod SSH readiness. Replacing the container interrupts connections and execution; persistent sessions resume only from saved state.

## Validation and rollout

Run unit/client tests and the complete native amd64/arm64 disposable container smoke. It exercises plain WebSocket RPCs without an Authorization header or credential files, simultaneous desktop proxy/network clients, reconnect, daemon/relay recovery and the ordinal gate. Preserve existing SSH/Docker/GHCR/state checks. No model call is needed.

After separate publication approval, record the new immutable registry digest and prepare the inactive k3s-gitops canary. It sets the workload partition to `2` and adds port `8787` to the existing `codex-devbox-2` Service. No new Service, NetworkPolicy, Vault resource or Certificate is needed. After deployment approval, verify readiness and the client smoke from a tailnet device, then saved-thread continuation and Desktop UI behavior.
