# Direct Codex App Server access

The proposed `codex-0.162.1-r2` image provides an opt-in plain WebSocket relay to the existing managed daemon. Default containers keep SSH-only startup. This review candidate is not publication or deployment evidence.

## Start and connect

Only two runtime settings exist:

| Setting | Meaning |
| --- | --- |
| `CODEX_APP_SERVER_ENABLED=1` | Start the relay and ensure the managed daemon is running. Omit to keep it off. |
| `CODEX_APP_SERVER_ORDINAL=2` | Optional restriction to hostname `codex-devbox-2`. Other ordinals stay off. |

The relay listens on `0.0.0.0:8787`, accepts WebSocket upgrades at `/`, and forwards raw frames to `/home/codex/.codex/app-server-control/app-server-control.sock`. There is no App Server token, TLS certificate, Secret mount, dedicated hostname certificate, or credential rotation. Any process able to reach the port can control this trusted Codex environment. Browser Origin requests remain rejected; this endpoint is intended for service clients.

For the current Kubernetes StatefulSet, a caller Pod can use the existing per-Pod DNS:

```text
ws://codex-devbox-2.codex-devbox-headless.codex-devbox.svc:8787/
```

The existing headless Service provides DNS for each named Pod. This address resolves directly to ordinal 2; it does not load-balance among Devboxes and requires no new Service or port added to the headless Service. Do not use the bare headless Service name, which can resolve multiple Pods. A direct Pod IP also works but may change after replacement. See [Kubernetes stable network identity](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-network-id).

This address is for callers on the Pod network. It does not create a new route through the existing Tailscale SSH/preview proxies. Keep those existing Services and routes unchanged. Callers with restricted egress need a separately scoped allow rule when integrated.

Use the [TypeScript client](../../codex-remote-devbox/examples/app-server-client/README.md). Supply only `CODEX_APP_SERVER_URL` for the read-only smoke command. Initialize each connection once, then start or resume a thread on the selected Devbox. Persist `devbox identity/endpoint + threadId`; reconnect to the same ordinal and reconcile state before retrying an uncertain operation. Clarification/approval handlers and task acceptance belong to the calling application.

## Lifecycle

The optional worker uses `codex app-server daemon start` when the Unix daemon is unavailable. The official command owns daemon identity and locking. Relay recovery is independent of SSH; restarting the relay does not intentionally stop the shared daemon. An unresponsive but still-running daemon is surfaced as unavailable rather than forcibly killed. The daemon receives the same image-owned Docker/Testcontainers environment as SSH sessions.

`GET /livez` checks the relay process. `GET /readyz` verifies that the Unix daemon accepts a WebSocket handshake. Neither invokes a model; readiness does not prove inference authentication or project readiness. Do not couple these checks to whole-Pod SSH readiness. Replacing the container interrupts connections and execution; persistent sessions resume only from saved state.

## Validation and rollout

Run unit/client tests and the complete native amd64/arm64 disposable container smoke. It exercises plain WebSocket RPCs without an Authorization header or credential files, simultaneous desktop proxy/network clients, reconnect, daemon/relay recovery and the ordinal gate. Preserve existing SSH/Docker/GHCR/state checks. No model call is needed.

After separate publication approval, record the new immutable registry digest and prepare the inactive k3s-gitops canary. It modifies only the ordinal-2 workload template with a partition of `2`; no new Service, NetworkPolicy, Vault resource or Certificate is needed. Live Pod DNS, caller access, saved-thread continuation and Desktop UI acceptance occur after deployment approval.
