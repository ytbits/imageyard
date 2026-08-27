# Changelog

## 2026-08-26 - Add Runtime GHCR Docker Client Authentication

- Bumped the Codex remote devbox packaging revision to immutable `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r5` while preserving Codex CLI `0.149.0`, the remote-Docker bridge, the exact nine-file Docker-host contract, both state mounts, and the inbound SSH interface.
- Added a fail-closed two-file GHCR source contract at `/run/secrets/ghcr/ghcr_username` and `/run/secrets/ghcr/ghcr_pat`, with root source modes `0444`/`0400` and runtime-only UID/GID `1000` mode-`0600` copies beneath a mode-`0700` `/run/codex-remote-devbox/ghcr/` directory.
- Added the host-scoped `docker-credential-codex-ghcr` helper so Docker CLI, Buildx, Compose, and Testcontainers registry requests can authenticate through the runtime credential without `docker login`, credential environment variables, or PAT persistence in Home. The helper exposes all GHCR capabilities granted by the supplied PAT and package ACLs and does not make registry availability an SSH-readiness gate.
- Added kernel-lock-serialized, invalid-UTF-8-, ownership-, symlink-, and hardlink-safe atomic management of only `credHelpers["ghcr.io"]="codex-ghcr"` while preserving unrelated valid Docker configuration and existing legacy GHCR auth under a single-writer contract. Killed image-owned writers leave only strictly named mode-`0600` temporary files that the next locked transaction validates and removes safely. Added explicit idempotent `scrub-legacy-auth` and `disable` operations for post-acceptance migration and staged rollback; neither operation prints or backs up credential values. Documented that Docker and arbitrary same-UID editors do not honor the image-private lock, so startup runs before sshd and manual actions require quiescing every external config writer.
- Documented the trusted-user boundary: `codex` has full sudo and can deliberately extract a usable runtime credential, while all Devboxes sharing the Mac daemon can observe cached private images. The helper limits accidental persistence and registry scope; it is neither pull-only enforcement nor tenancy isolation.
- Expanded focused and dual-architecture smoke coverage for helper protocol, deterministic authenticated remote-Docker requests, hostile/malformed/symlink Home configuration, exact merge/scrub/disable semantics, kernel serialization of image-owned actions, pre-rename replacement detection, crash recovery, source/runtime modes, missing and malformed Secret inputs, restart/signal contracts, and absence of PAT material from Home, state, image layers, history, and logs.

## 2026-08-24 - Add Supervised Testcontainers Docker Bridge

- Bumped the Codex remote devbox packaging revision to immutable `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r4` while retaining Codex CLI `0.149.0`, the exact nine-file Docker-host Secret contract, both state mounts, and the inbound SSH interface.
- Added an image-owned AF_UNIX bridge at `/run/codex-remote-devbox/docker-bridge/docker.sock`, with a private `1000:1000` mode `0700` directory and `1000:1000` mode `0600` socket, no TCP listener, inode-safe stale-socket handling, and explicit nonzero process exit that preserves detected path replacements through real process teardown.
- Added one fixed, shell-free `/usr/bin/ssh` plus remote `docker --host=unix://<validated-path> system dial-stdio` transport per connection, with concurrent HTTP, binary hijack, half-close, expected-disconnect, stderr-isolation, and bounded child-reaping behavior.
- Switched authenticated SSH sessions to the local bridge `DOCKER_HOST` and derived `TESTCONTAINERS_HOST_OVERRIDE` from the validated `ssh_host`, while setting the remote Ryuk bind target through `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` and keeping `DOCKER_CONTEXT` absent.
- Added a root supervisor that starts the bridge as `codex`, waits for its socket before starting sshd, fails the container if either service exits unexpectedly, and performs bounded signal cleanup without orphan processes or owned stale sockets. Remote Mac or Docker unavailability remains a per-request failure and does not block SSH readiness.
- Documented the accepted non-isolation boundary: Devboxes sharing the credential use one daemon-wide Mac namespace and resource pool, while Testcontainers and published ports bind on the Mac and remain subject to Docker Desktop, firewall, LAN, and tailnet exposure policy; the local socket adds transport but no Kubernetes Docker TCP endpoint or per-Devbox tenancy.
- Added focused Node bridge tests plus dual-architecture deterministic fake SSH/dial-stdio smoke coverage for exact argv and session environment, concurrent Docker clients, hijacked streams, offline recovery, hostile Home configuration, process supervision, socket security, and the no-daemon/no-host-socket boundary.

## 2026-08-24 - Add Pinned Remote Docker Client Layer

- Bumped the Codex remote devbox packaging revision to immutable `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r3` while preserving Codex CLI `0.149.0` and all `r2` state, SSH-server, `tini`, signal, and no-init-container behavior.
- Added only Docker's official pinned Bookworm CLI, Buildx, and Compose packages for both `linux/amd64` and `linux/arm64`; Docker Engine, `dockerd`, `containerd`, DinD, Podman, nerdctl, local sockets, and daemon listeners remain excluded.
- Added a fail-closed read-only Docker-host Secret contract with Ed25519 client-key and alias-keyed known-host fingerprint verification, runtime-only key copies, a strict system `docker-host`/`HostKeyAlias docker-host` SSH stanza, and runtime sshd `DOCKER_HOST` injection without `DOCKER_CONTEXT`.
- Kept remote-host reachability out of startup readiness so a valid offline Mac can recover without a Pod restart, and documented that remote bind mounts resolve on the Mac daemon rather than under `/workspaces`.
- Expanded two-architecture validation and publication evidence for exact Docker package versions, malformed and mismatched Secret bundles, source/runtime immutability, interactive and command SSH environments, daemon exclusions, config digests, and post-publication smoke.
- Added bounded, read-only post-push registry-visibility retries anchored to the pushed immutable index digest; the verifier never retries publication.

## 2026-08-22 - Bootstrap Codex Remote Devbox State Mounts

- Bumped the Codex remote devbox packaging revision to `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r2` without changing Codex CLI `0.149.0`.
- Required explicit mountpoints at `/home/codex` and `/workspaces`; missing, parent-only, invalid, symlinked, read-only, or unusable state roots now fail closed before SSH starts.
- Added image-native, nonrecursive bootstrap that normalizes only each mount root to UID/GID `1000` and mode `0700`, performs a temporary write probe as `codex`, and preserves all descendant state.
- Locked the secret contract so validation completes before state mutation, key sources remain unchanged, runtime copies stay under `/run`, and key material never enters state or logs.
- Locked the root `tini -g` to entrypoint to foreground sshd process contract and the bounded signal-driven shutdown requirement.
- Expanded release guidance and validation expectations for no-copy named volumes, bootstrap idempotence, nested metadata preservation, invalid state roots, secret non-interference, and both native architectures.

## 2026-08-22 - Add Codex Remote Devbox Image

- Added the `codex-remote-devbox` SSH image for Codex Desktop remote connections, based on the digest-pinned Node 24 Bookworm image with Codex CLI `0.149.0`.
- Defined the stable port, user, filesystem, runtime key-file, tool, sudo, and credential boundaries without coupling the public image to a deployment platform.
- Added separate validation and publish workflows with amd64/arm64 smoke tests, immutable fail-closed GHCR checks, and no moving tags.
- Established `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r1` as the initial immutable release.
- Added an architecture decision record and release runbook covering the image contract, local and Codex Desktop validation, publishing, digest verification, and rollback.

## 2026-08-11 - Update GitHub Image Ownership References

- Updated current Multica runtime GHCR coordinates and OCI source labels from the former GitHub owner to `ytbits`.
- Left the owner-derived publishing workflows and immutable image tags unchanged.

## 2026-08-08 - Upgrade Multica Runtime Images

- Upgraded both Multica runtime images from `v0.3.29` to `v0.4.21`.
- Upgraded the Codex CLI from `0.142.4` to `0.147.0` and reset the immutable image revision to `v0.4.21-codex-0.147.0-r1`.
- Upgraded Claude Code from `2.1.197` to Anthropic stable-channel version `2.1.220` and reset the immutable image revision to `v0.4.21-claude-2.1.220-r1`.
- Added Anthropic's documented Alpine runtime dependencies for the native Claude Code package.
- Serialized each image's publish jobs and added fail-closed checks that refuse to overwrite an existing immutable GHCR tag.
- Documented repeatable local smoke tests, publishing, manifest verification, and rollback procedures.

## 2026-07-01 - Migrate Multica Runtime Images

- Added the Multica Codex and Claude runtime image definitions under `multica-runtime/`.
- Added scoped publish workflows for the Multica runtime images.
- Bumped the migrated image revision tags to `v0.3.29-codex-0.142.4-r2` and `v0.3.29-claude-2.1.197-r2`.
- Updated repository guidance to reflect the first active image contracts.

## 2026-07-01 - Bootstrap Repository Guidance

- Added generic repository documentation for centralized container image definitions, scoped CI build pipelines, and registry publishing automation.
- Added canonical shared contributor and agent guidance in `AGENTS.md`.
- Added ADR and runbook placeholders for future image decisions and repeatable build or publish procedures.
- Documented the default workflow to commit focused changes, push feature branches, and open draft PRs.
- Documented that the current repository state is documentation-only and does not include image definitions, workflows, publishing, tags, or migrations.
