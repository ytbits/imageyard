# Architecture Decision Records

Use this directory for durable decisions about image layout, build tooling, tag policy, registry publishing, workflow structure, and other tradeoffs that future contributors should not have to rediscover.

## Records

- [ADR 0001: Codex Remote Devbox Image Contract](0001-codex-remote-devbox-contract.md) — SSH runtime, user and filesystem interface, privilege and credential boundaries, immutable tags, and multi-architecture publication.
- [ADR 0002: Opt-in Codex App Server Access](0002-codex-app-server-access.md) — direct plain WebSocket access to the existing per-user daemon and independent gateway recovery.
