# imageyard

This file is the canonical shared agent and contributor contract for this repository.

`AGENTS.md` is the source of truth for both Codex and Claude guidance. `CLAUDE.md` is retained as a compatibility symlink to this file for tools that still look for that path.

Centralized repository for container image definitions, CI build pipelines, and registry publishing automation.

## Repository Purpose

This repository is dedicated to image-building work across container images maintained together. It should collect image definitions, image-specific build assets, scoped CI workflows, publishing automation, runbooks, and decision records.

The repository currently hosts the Codex remote devbox and Multica runtime image definitions with scoped validation and publish workflows. Additional image projects should be added under their own clearly named directories as they are consolidated.

## Current Repository Structure

```text
imageyard/
├── .github/
│   └── workflows/
│       ├── publish-codex-remote-devbox.yml
│       ├── publish-multica-runtime-claude.yml
│       ├── publish-multica-runtime-codex.yml
│       └── validate-codex-remote-devbox.yml
├── codex-remote-devbox/
│   ├── .dockerignore
│   ├── Dockerfile
│   ├── docker-bridge-client-smoke.js
│   ├── docker-bridge.js
│   ├── docker-bridge.test.js
│   ├── entrypoint.sh
│   ├── fake-docker-backend.py
│   ├── fake-docker-sshd_config
│   ├── ghcr-auth-command.sh
│   ├── ghcr-auth-config.js
│   ├── ghcr-auth.test.js
│   ├── ghcr-credential-helper.js
│   ├── smoke-test.sh
│   ├── sshd_config
│   └── supervisor.js
├── multica-runtime/
│   ├── claude.Dockerfile
│   ├── claude-entrypoint.sh
│   ├── codex.Dockerfile
│   └── codex-entrypoint.sh
├── docs/
│   ├── adr/
│   │   └── 0001-codex-remote-devbox-contract.md
│   ├── runbooks/
│   │   ├── codex-remote-devbox-release.md
│   │   └── multica-runtime-release.md
│   └── changelog.md
├── README.md
├── AGENTS.md
└── CLAUDE.md -> AGENTS.md
```

## Current Image Contracts

### Codex Remote Devbox

- Directory and build context: `codex-remote-devbox/`
- Dockerfile: `codex-remote-devbox/Dockerfile`
- Base image: `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`
- Codex CLI package: `@openai/codex@0.149.0`
- Published platforms: `linux/amd64`, `linux/arm64`
- Canonical tag: `codex-0.149.0-r5`
- Release target: `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r5`
- Docker client packages: `docker-ce-cli=5:29.7.2-1~debian.12~bookworm`, `docker-buildx-plugin=0.36.1-1~debian.12~bookworm`, and `docker-compose-plugin=5.5.0-1~debian.12~bookworm` from Docker's official Debian repository
- SSH interface: TCP `2222`, public-key-only login as `codex` UID/GID `1000` with Bash
- Required state mountpoints: `/home/codex` and `/workspaces`
- Authorized keys: `/run/secrets/ssh-access/authorized_keys`
- Ed25519 host key: `/run/secrets/ssh-host/ssh_host_ed25519_key`
- Docker-host Secret directory: `/run/secrets/docker-host`
- GHCR credential files: `/run/secrets/ghcr/ghcr_username` and `/run/secrets/ghcr/ghcr_pat`
- Startup: root `tini` to the validating entrypoint to a root supervisor; the supervisor runs the Docker bridge as `codex` UID/GID `1000` and foreground OpenSSH as root
- Smoke tests: both architectures, required mountpoints, fresh-volume bootstrap, nested metadata preservation, idempotence, positive and negative SSH authentication, state and secret failure cases, Docker package and remote-SSH contracts, fixed-argv bridge behavior, concurrent HTTP and hijacked streams, offline requests, exact SSH-session environment, GHCR helper protocol and authenticated Docker client requests, hostile Docker Home configuration, deliberate legacy-auth migration and rollback cleanup, supervisor failure and signal cleanup, user and sudo contract, tool boundaries, app-server command availability, stable host identity, persistence, listener checks, and secret non-interference

Both `/home/codex` and `/workspaces` must be real, non-symlink directories and exact mountpoints listed in `/proc/self/mountinfo`; an image-layer directory or parent-only mount is insufficient. The entrypoint validates both mountpoints, the fixed `codex` identity, the SSH inputs, and OpenSSH configuration before changing state. It then non-recursively normalizes only each mount root to UID/GID `1000` and mode `0700`, requires that exact postcondition, and runs a temporary create/remove probe as `codex`. It must never seed, wipe, recursively change, or migrate descendant data. Any invalid, read-only, or unusable root fails closed before SSH starts.

The authorized-keys input accepts bare OpenSSH public-key lines only; per-key options are not part of the image contract. Source keys are read-only inputs: copy them to runtime files without modifying their bytes or metadata, writing them into state, or printing them. The Codex remote devbox is a trusted, single-user development image. It grants `codex` full passwordless sudo as an explicit exception, but it must not require privileged mode, mount a host or daemon Docker socket, expose a Docker daemon listener, or use broad host-filesystem mounts. The image-owned Unix bridge socket is the only local Docker endpoint. It includes a lean Node, Python, Git, GitHub CLI, SSH, build toolset, and only the official pinned Docker CLI, Buildx, and Compose client packages. It excludes Docker Engine, `dockerd`, `containerd`, DinD, Podman, nerdctl, Kubernetes and infrastructure CLIs, `nvm`, and `pyenv`.

The image must fail closed when either runtime SSH key is missing, empty, invalid, or unsafe. It must never generate an ephemeral host identity, print key material, or bake Codex, GitHub, API, SSH, or user credentials into an image layer, build argument, label, or test fixture. Interactive authentication is performed after connection, and persistent user state is an external runtime concern.

The Docker-host Secret directory must provide exactly named regular, non-symlink, nonempty inputs: `docker_host`, `ssh_alias`, `ssh_host`, `ssh_port`, `ssh_user`, `ssh_client_ed25519_private_key`, `ssh_client_ed25519_fingerprint`, `ssh_host_ed25519_fingerprint`, and `ssh_known_hosts`. The SSH alias and OpenSSH host-key alias are fixed to `docker-host`; `HostName` remains the separately configured MagicDNS host. Validate safe field syntax, the Ed25519 client key's derived fingerprint, and exactly one matching Ed25519 known-hosts entry keyed by `docker-host` without printing values or fingerprints. Copy only the private key and known-hosts file on every start to `/run/codex-remote-devbox/docker-host/`, owned by UID/GID `1000` and mode `0600`; never persist them under `/home/codex` or modify `~/.ssh`.

The GHCR Secret contract is exactly two root-owned regular, non-symlink, nonempty source files: `/run/secrets/ghcr/ghcr_username` at mode `0444` and `/run/secrets/ghcr/ghcr_pat` at mode `0400`. Validate a GitHub-compatible username and printable single-line token without printing either value. On every start, recreate `/run/codex-remote-devbox/ghcr/` as UID/GID `1000` mode `0700` with exact files `ghcr_username` and `ghcr_pat` as UID/GID `1000` mode `0600`; never write the PAT, a derived auth value, or a backup containing either into `/home/codex`.

Install the root-owned `docker-credential-codex-ghcr` helper and allow it to return the runtime credential only for normalized `ghcr.io` requests made as UID/GID `1000`. Reject helper writes, erases, unsupported hosts, unsafe runtime metadata, malformed values, and oversized input with one generic non-secret error. The helper exposes all GHCR operations permitted by the supplied PAT and package ACLs, including push when granted; never describe it as pull-only. A GHCR outage or revoked token fails the Docker command at request time and must not become an SSH-readiness gate. Because `codex` has full sudo and the helper must yield the credential to Docker, code running as this trusted user can deliberately extract it; the helper limits accidental persistence and host scope, not exfiltration.

Manage only `credHelpers["ghcr.io"]="codex-ghcr"` in `~/.docker/config.json`. Require a codex-owned, non-symlink directory and single-link regular config file, fatal UTF-8 and valid JSON, and object-valued `auths`/`credHelpers`; normalize the directory and output file to modes `0700` and `0600`. Serialize every image-owned public action through the fixed runtime lock with kernel `flock`, then update through a same-directory single-link mode-`0600` temporary file, file sync, full identity revalidation, atomic rename, and directory sync. At the start of each locked transaction, validate and remove only exact, safe image-named stale temporary files left by a prior image-owned process crash; fail closed on symlinks, hardlinks, wrong ownership/mode, or changed identity. The lock is private to `codex-ghcr-auth`: Docker and arbitrary same-UID editors do not honor it, and POSIX rename provides no compare-and-swap across the residual post-check/pre-rename window. Boot-time enable must therefore run before sshd exposes a session, and manual enable, scrub, or disable requires quiescing `docker login`, `docker logout`, and every other writer of `~/.docker/config.json`; never claim that an uncooperative concurrent writer is preserved. Under that precondition, preserve all unrelated valid JSON. Initial enable must not remove `auths["ghcr.io"]` or overwrite a differently managed helper; remove the legacy auth only through explicit, idempotent `codex-ghcr-auth scrub-legacy-auth` after helper-backed acceptance. Provide exact, idempotent `codex-ghcr-auth disable` rollback cleanup that deletes only the image-managed helper mapping and never prints configuration values.

Generate `/etc/ssh/ssh_config.d/20-codex-docker-host.conf` as a root-owned exact `Host docker-host` stanza with the validated hostname, user, port, `HostKeyAlias docker-host`, runtime identity and known-hosts paths, plus `IdentitiesOnly yes`, `BatchMode yes`, `ConnectTimeout 10`, public-key-only authentication, strict host checking, Ed25519-only host keys, no host-key updates, and no agent forwarding. Validate effective `ssh -G -F /etc/ssh/ssh_config docker-host` output without contacting the host or leaking values. Continue validating `docker_host` as an `ssh://docker-host/<absolute-socket-path>` consistency input; derive the bridge's remote Unix socket path from it, but do not export that URI as `DOCKER_HOST`.

The image-owned bridge listens only at `/run/codex-remote-devbox/docker-bridge/docker.sock`. Its runtime directory and socket must be real, non-symlink objects owned by UID/GID `1000`, with modes `0700` and `0600` respectively. Refuse unsafe or live stale-path occupants, remove only a verified stale socket, retain the bound inode identity, and treat later directory or socket replacement as fatal without unlinking an attacker-controlled replacement. On detected identity compromise, reap active children and use an explicit nonzero bridge-process exit so Node/libuv cannot close the listener and unlink the replacement during normal teardown. The bridge must open no TCP listener.

For each accepted Unix connection, spawn exactly one `/usr/bin/ssh` child with no shell interpolation and a fixed argument structure: explicit system config, no TTY, cleared forwarding, no multiplexing, alias `docker-host`, and remote `docker --host=unix://<validated-path> system dial-stdio`. Use a minimal fixed environment, discard raw SSH stderr, relay bytes bidirectionally for concurrent HTTP and hijacked streams, preserve half-close behavior, tolerate expected `EPIPE` and disconnects, and reap each child with bounded `TERM` then `KILL`. A remote SSH/Docker failure is per-connection and must not kill the bridge or prevent SSH readiness.

Generate a runtime sshd configuration from the immutable base and append one `SetEnv` directive containing exactly `DOCKER_HOST=unix:///run/codex-remote-devbox/docker-bridge/docker.sock`, `TESTCONTAINERS_HOST_OVERRIDE=<validated ssh_host>`, and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`; validate it with `sshd -t` and use it for foreground sshd. Never set `DOCKER_CONTEXT`. These values belong to authenticated command and interactive SSH sessions, including Codex Desktop sessions; direct container exec does not traverse sshd and must not be treated as equivalent environment evidence.

Docker SSH URLs may specify the Mac's non-default socket path. Build contexts are sent to the remote engine, but bind mounts resolve on the Mac daemon rather than against `/workspaces`. Keep the legacy Home alias `docker-mac` untouched; the image-owned alias is only `docker-host`.

Treat the bridge as a transport, not an isolation boundary. All Devboxes using the shared Docker-host credential target one Mac daemon, so container names and state, networks, images, volumes, build cache, and CPU/memory contention are daemon-wide rather than Devbox-isolated. Testcontainers and `-p` published ports bind on the Mac Docker host and may be reachable by LAN or tailnet peers under Docker Desktop, host-firewall, and tailnet policy. Do not describe the private local Unix socket as tenancy isolation, and do not add Kubernetes-side Docker TCP exposure.

Codex Desktop starts the remote app server through SSH. The image must expose only SSH over TCP, must not prestart or publish an app-server listener, and must keep the remote login shell's `PATH` free of noisy interactive-only setup. The process contract is root `tini -g` to the root validating entrypoint to the image-owned supervisor. The supervisor prepares and verifies the private bridge runtime directory, removes only a safely identified stale socket, starts the bridge as UID/GID `1000`, waits for its ready socket, and then starts foreground sshd as root. An unexpected bridge or sshd exit is fatal: terminate the sibling, clean up the owned socket safely, and exit nonzero. On container signals, send bounded `TERM` then `KILL` to both services; the bridge separately reaps every per-connection SSH child so no process or stale socket remains.

Codex remote devbox tags use `codex-<CODEX_VERSION>-r<REVISION>`. Reset to `r1` when Codex changes; increment the revision for packaging changes at the same Codex version. Never publish or overwrite a moving tag. Base-image and system-package versions belong in the Dockerfile, OCI labels, and documentation, not in the tag.

Validation and publication remain separate. The validation workflow has read-only repository permissions and builds and smoke-tests both target platforms. The publish workflow is limited to image-producing changes on `main` or manual dispatches targeting `main`, owns the GHCR write permission, and checks the exact immutable tag before building and again immediately before pushing. Registry authentication, network, or ambiguous-not-found failures must stop publication. After a successful push, bounded read-only retries may tolerate registry read-after-write visibility, but all evidence must remain anchored to the pushed index digest; retry exhaustion or any digest mismatch fails verification and must never cause a republish.

### Multica Codex Runtime

- Dockerfile: `multica-runtime/codex.Dockerfile`
- Entrypoint: `multica-runtime/codex-entrypoint.sh`
- Base image: `ghcr.io/multica-ai/multica-backend:v0.4.21`
- Codex CLI package: `@openai/codex@0.147.0`
- Build context: `multica-runtime`
- Published platforms: `linux/amd64`, `linux/arm64`
- Canonical image tag: `v0.4.21-codex-0.147.0-r1`
- Published image name: `ghcr.io/ytbits/multica-runtime-codex:v0.4.21-codex-0.147.0-r1`
- Smoke tests: Multica/Codex versions, non-root user, Git/GitHub CLI/SSH/Node/npm/bubblewrap availability, daemon flags, and safe required-environment failures

### Multica Claude Runtime

- Dockerfile: `multica-runtime/claude.Dockerfile`
- Entrypoint: `multica-runtime/claude-entrypoint.sh`
- Base image: `ghcr.io/multica-ai/multica-backend:v0.4.21`
- Claude Code package: `@anthropic-ai/claude-code@2.1.220` from Anthropic's stable release channel
- Build context: `multica-runtime`
- Published platforms: `linux/amd64`, `linux/arm64`
- Canonical image tag: `v0.4.21-claude-2.1.220-r1`
- Published image name: `ghcr.io/ytbits/multica-runtime-claude:v0.4.21-claude-2.1.220-r1`
- Smoke tests: Multica/Claude versions, non-root user, Git/GitHub CLI/SSH/Node/npm/ripgrep availability, daemon flags, and safe required-environment failures

The Multica runtime images must run as the non-root `multica` user and must not bake runtime secrets into the image. Runtime secrets belong in Kubernetes, Vault, or another runtime secret source.

Each Multica runtime image has its own publish workflow. Multica runtime workflows trigger only when that workflow file or the corresponding runtime Dockerfile/entrypoint changes, or when manually dispatched. Publishes are serialized per image and must fail closed rather than overwrite an existing immutable tag.

## Required Git Workflow for All Changes

These steps must be included in every implementation plan unless explicitly told otherwise:

- Create a feature branch from `main` using the `codex/` prefix
  - Example: `git checkout -b codex/<short-feature-name>`
- Keep commits focused and action-oriented
  - Example: `add image build documentation scaffold`
- Do not bundle unrelated refactors with the main change
- Commit focused changes, push the feature branch, and open a draft PR by default unless explicitly told otherwise

## Image Organization Guidance

- Keep image definitions organized by image or source project.
- Keep Dockerfiles, entrypoints, smoke tests, build assets, and runbooks close enough that image ownership is obvious.
- Keep build and publish workflows scoped to the images they affect.
- Use workflow path filters or equivalent guardrails so documentation-only changes and unrelated image changes do not publish images.
- Document the build context, Dockerfile path, supported platforms, registry target, and tag policy when adding an image.
- Keep image tags explicit and immutable by default.
- Avoid moving tags such as `latest`, `stable`, or major/minor aliases unless the tag behavior is explicitly documented in README, changelog, and an ADR or runbook.

## Security and Publishing Guidance

- Do not bake runtime secrets, credentials, tokens, kubeconfigs, cloud credentials, SSH keys, or local developer state into images.
- Do not expose secrets through Docker build args, image labels, workflow logs, README examples, or checked-in config files.
- Runtime credentials should be provided by the deployment platform, secret manager, or user-controlled runtime configuration.
- Keep registry publishing automation explicit about registry, image name, tag set, platforms, and authentication source.
- Prefer image-specific publish workflows over broad repository-wide publish jobs when images have independent release contracts.
- Document any exception to the default immutable-tag policy before publishing.

## Documentation Standards

Every meaningful image, workflow, publishing, or repository convention change should update the relevant docs:

1. `README.md` for repository purpose, current image inventory, and contributor entrypoint changes
2. `AGENTS.md` for the canonical shared agent, workflow, release, and contributor contract
3. `CLAUDE.md` only as the compatibility symlink path for tools that still expect it
4. `docs/changelog.md` for meaningful image, workflow, infrastructure, and documentation changes
5. `docs/runbooks/` when build, smoke-test, publish, release, rollback, or troubleshooting procedures become concrete or materially change
6. `docs/adr/` when architecture, tooling, image layout, tag policy, registry policy, or release decisions and tradeoffs are intentionally locked in

Keep `README.md`, `AGENTS.md`, runbooks, ADRs, and the changelog aligned with implemented behavior.

Self-evaluation checklist:

1. Did I add or change an image contract? If yes, document the Dockerfile path, build context, platforms, tags, and smoke tests.
2. Did I make a durable decision between alternatives? If yes, add or update an ADR.
3. Did I add steps someone must repeat or troubleshoot? If yes, add or update a runbook.
4. Did anything meaningful change? If yes, update the changelog.
5. Did project conventions, tooling, publishing process, or repo context change? If yes, update `AGENTS.md`.
