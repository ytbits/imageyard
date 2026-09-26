# imageyard

Centralized container image definitions, scoped CI build pipelines, and registry publishing automation.

## Purpose

`imageyard` is the shared home for image-building work. It is intended to collect Dockerfiles, image-specific build assets, CI workflows, publishing rules, runbooks, and decision records for container images that are maintained together.

This repository includes the Codex remote devbox and Multica runtime image definitions with scoped validation and publish workflows. Additional image projects can be added under their own directories as they are consolidated.

## Repository Structure

Future image work should keep image definitions and supporting files organized by image or source project. Build and publish automation should stay scoped to the images it affects so documentation-only changes or unrelated image changes do not publish images accidentally.

Current layout:

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
│   ├── app-server-smoke.js
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
├── docs/
│   ├── adr/
│   ├── runbooks/
│   └── changelog.md
├── README.md
├── AGENTS.md
└── CLAUDE.md -> AGENTS.md
```

## Current Images

### Codex Remote Devbox

The `codex-remote-devbox/` directory defines an SSH-accessible development environment for Codex Desktop remote connections:

- Image: `ghcr.io/ytbits/codex-remote-devbox:codex-0.157.1-r1`
- Dockerfile and build context: `codex-remote-devbox/Dockerfile` and `codex-remote-devbox/`
- Base: `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`
- Codex CLI: `@openai/codex@0.157.1`
- Published platforms: `linux/amd64`, `linux/arm64`
- SSH contract: port `2222`, user `codex` with UID/GID `1000` and Bash
- Required state mountpoints: `/home/codex` and `/workspaces`
- Runtime access key: `/run/secrets/ssh-access/authorized_keys`
- Runtime host key: `/run/secrets/ssh-host/ssh_host_ed25519_key`
- Runtime Docker-host bundle: `/run/secrets/docker-host/`
- Runtime GHCR bundle: `/run/secrets/ghcr/ghcr_username` and `/run/secrets/ghcr/ghcr_pat`

The current release upgrades Codex CLI from `0.149.0` to stable `0.157.1` and resets the packaging revision to `r1`. It preserves the runtime contracts introduced through `codex-0.149.0-r5`, including the GHCR helper, Docker bridge, SSH interface, and state mounts. The pinned Node base and Docker client packages are unchanged. The larger upstream native Codex payload increases image storage and transfer requirements.

Both state paths must be explicit mountpoints; image-layer directories or a mount on only a parent path do not satisfy the contract. After validating the fixed identity, mount types, runtime keys, and OpenSSH configuration, the root entrypoint bootstraps only the two mount roots to UID/GID `1000` and mode `0700`, then verifies that `codex` can create and remove a temporary probe. Bootstrap is nonrecursive: it never seeds, wipes, changes, or migrates existing descendants. A missing, non-directory, symlinked, non-mountpoint, read-only, or otherwise unusable state root fails closed before SSH starts.

The authorized-keys file accepts one or more bare OpenSSH public-key lines; per-key options are intentionally not accepted. Runtime key sources are treated as read-only inputs, copied into runtime files, and never written into either state mount. The root process chain is `tini -g` to the validating entrypoint to an image-owned supervisor. The supervisor starts the Docker bridge as `codex` UID/GID `1000`, waits for its Unix socket contract, and then starts foreground OpenSSH as root. An unexpected bridge or sshd exit terminates the other service and fails the container; termination signals trigger bounded `TERM` then `KILL` cleanup. SSH is public-key-only and fails closed when either runtime SSH key or any Docker-host bundle input is missing or invalid. The image grants `codex` full passwordless sudo as an explicit single-user development convenience, but it does not require privileged mode, mount a host Docker socket, or expose a Docker daemon listener.

Revision `r3` added only Docker client packaging and remote-host wiring; Codex remained `0.149.0`, and every `r2` state, SSH-server, `tini`, signal, and no-init-container guarantee remained in force. The image installs only Docker's official pinned `docker-ce-cli` (`5:29.7.2-1~debian.12~bookworm`), `docker-buildx-plugin` (`0.36.1-1~debian.12~bookworm`), and `docker-compose-plugin` (`5.5.0-1~debian.12~bookworm`). It does not install Docker Engine, `dockerd`, `containerd`, DinD, Podman, or nerdctl.

Revision `r4` adds a Testcontainers-compatible local Docker transport without changing Codex or the nine-file remote-host input contract. The bridge owns `/run/codex-remote-devbox/docker-bridge/docker.sock`; its containing directory is `1000:1000` mode `0700`, and the socket is `1000:1000` mode `0600`. Each accepted connection starts one `/usr/bin/ssh` child with a fixed, shell-free argument vector for `docker-host` and `docker --host=unix://<validated-path> system dial-stdio`. The bridge ignores raw SSH stderr, supports concurrent HTTP and hijacked byte streams with half-close behavior, reaps children with bounded escalation, monitors socket identity, and never opens a TCP listener. A per-connection remote failure is not bridge-fatal, so an offline Mac makes Docker requests fail without delaying SSH readiness.

Revision `r5` adds automatic client-side GHCR authentication from two deployment-provided files without running `docker login` or persisting the PAT in Home. Startup requires root-owned regular files `/run/secrets/ghcr/ghcr_username` (mode `0444`) and `/run/secrets/ghcr/ghcr_pat` (mode `0400`), validates them without printing either value, and copies them to `/run/codex-remote-devbox/ghcr/` as UID/GID `1000`, directory mode `0700`, and file mode `0600`. The root-owned `docker-credential-codex-ghcr` helper serves credentials only for `ghcr.io`; Docker invokes it through the non-secret `credHelpers["ghcr.io"]="codex-ghcr"` mapping. A revoked token or GHCR outage fails the affected registry command without delaying SSH readiness.

The image-owned `codex-ghcr-auth` command serializes its own changes with a kernel lock and atomically replaces valid `~/.docker/config.json` state while managing only that exact helper mapping. It rejects invalid UTF-8, symlinks, hardlinks, unsafe ownership/modes, and a differently managed GHCR helper; the next locked transaction safely removes only validated image-named temporary files left by a killed image-owned writer. Docker and arbitrary editors do not honor this private lock, so boot enable runs before sshd and manual enable, scrub, or disable must be performed only while every other writer of `~/.docker/config.json` is quiesced. First boot intentionally leaves any legacy `auths["ghcr.io"]` value untouched; after helper-backed pull or push acceptance, an operator may run `codex-ghcr-auth scrub-legacy-auth` explicitly. `codex-ghcr-auth disable` removes only the exact image-managed helper mapping for a staged rollback. The helper exposes every GHCR operation permitted by the supplied PAT and package ACLs, including push when granted; it is not a pull-only boundary. Because `codex` has full sudo and must be able to use the credential, code running as that trusted user can deliberately extract it. The helper prevents accidental persistence and broad registry matching, not malicious exfiltration or per-Devbox isolation.

The required read-only Docker-host bundle contains `docker_host`, `ssh_alias`, `ssh_host`, `ssh_port`, `ssh_user`, `ssh_client_ed25519_private_key`, `ssh_client_ed25519_fingerprint`, `ssh_host_ed25519_fingerprint`, and `ssh_known_hosts`. The alias and host-key alias are fixed to `docker-host`; `HostName` remains the separately configured MagicDNS host. Startup validates the Ed25519 client key, the single alias-keyed pinned host entry, and the `ssh://docker-host/<absolute-socket-path>` URI without contacting the Mac. The URI remains an input-consistency contract; its path selects the remote Docker socket, while the SSH-session environment is generated as `DOCKER_HOST=unix:///run/codex-remote-devbox/docker-bridge/docker.sock`, `TESTCONTAINERS_HOST_OVERRIDE=<validated ssh_host>`, and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`. It never writes shared Docker SSH material under `/home/codex`, never sets `DOCKER_CONTEXT`, and does not make Mac or Docker Desktop reachability a readiness condition. These variables are injected by sshd into authenticated interactive and command sessions; a deployment-level direct exec is not an equivalent environment check.

The image also includes a lean Node, Python, Git, GitHub CLI, SSH, and build toolset. It deliberately excludes Kubernetes tools, infrastructure CLIs, `nvm`, and `pyenv`. No Codex, GitHub, API, SSH, or user credentials are baked into the image. Authenticate Codex and the GitHub CLI after connecting with `codex login --device-auth` and `gh auth login --git-protocol https`; the separate runtime GHCR helper does not authenticate either tool. Persist both required state mountpoints across replacement when their contents must survive. Docker and Testcontainers clients connect to the image-owned Unix bridge, which relays each connection to the pinned remote Mac engine over SSH. Build contexts are transferred by the client, but bind-mount source paths are resolved on the Mac daemon, not beneath the devbox's `/workspaces`; Ryuk's remote bind target remains `/var/run/docker.sock` through the socket override.

The bridge is a transport boundary, not a Docker-tenancy boundary. Devboxes that share this credential target the same Mac daemon and therefore share daemon-wide container names and state, networks, images, volumes, build cache, and CPU/memory contention. Testcontainers and `-p` published ports bind on the Mac Docker host and may be reachable by LAN or tailnet peers according to Docker Desktop, host-firewall, and tailnet policy. Revision `r5` adds no Kubernetes-side Docker TCP exposure; the private local Unix socket and per-client GHCR credential do not isolate one Devbox's Docker activity or already-cached private layers from another.

Codex Desktop starts its app server through the SSH connection, so the image does not start or expose an app-server listener. Both architecture smoke suites exercise that path with a bounded authenticated SSH stdio session: send `initialize`, verify the reported Codex version, `codexHome=/home/codex/.codex`, and Linux platform, then send `initialized` and require a successful `config/read` response and clean shutdown. The check runs against fresh and reused Home fixtures and verifies that the app server adds no TCP listener. See the official [remote connections](https://learn.chatgpt.com/docs/remote-connections) and [authentication](https://learn.chatgpt.com/docs/auth) documentation.

Codex remote devbox tags have the immutable form `codex-<CODEX_VERSION>-r<REVISION>`. A Codex upgrade resets the revision to `r1`; packaging-only changes increment it. The project never publishes `latest`, `stable`, or another moving alias.

### Multica Runtime

The `multica-runtime/` directory contains two Kubernetes-oriented Multica daemon runtime images:

- Codex runtime: `multica-runtime/codex.Dockerfile`
  - Entrypoint: `multica-runtime/codex-entrypoint.sh`
  - Base image: `ghcr.io/multica-ai/multica-backend:v0.4.21`
  - Codex CLI: `@openai/codex@0.147.0`
  - Published tag: `ghcr.io/ytbits/multica-runtime-codex:v0.4.21-codex-0.147.0-r1`
- Claude runtime: `multica-runtime/claude.Dockerfile`
  - Entrypoint: `multica-runtime/claude-entrypoint.sh`
  - Base image: `ghcr.io/multica-ai/multica-backend:v0.4.21`
  - Claude Code: `@anthropic-ai/claude-code@2.1.220` from Anthropic's stable release channel
  - Published tag: `ghcr.io/ytbits/multica-runtime-claude:v0.4.21-claude-2.1.220-r1`

Both images use the `multica-runtime` build context and publish for `linux/amd64` and `linux/arm64`. Release smoke tests verify the Multica/provider versions, non-root user, required tools, and safe missing-environment-variable failures.

Both workflows publish only explicit immutable tags. They do not publish a moving `latest` tag, serialize publishes per image, and fail closed if the target tag already exists or its availability cannot be verified.

## Scoped Validation and Publishing

The Codex remote devbox has separate validation and publish workflows. Validation runs on relevant pull requests, manual dispatches, and reusable workflow calls, and builds and smoke-tests both target platforms. Publishing runs only for image-producing changes on `main` or a manual dispatch targeting `main`. It authenticates to GHCR, checks the exact tag before building and again immediately before pushing, and fails closed unless the registry proves the immutable tag is absent.

Each Multica runtime image retains its own publish workflow. Workflows run on pushes to `main` only when that workflow or that image's Dockerfile/entrypoint changes, and they can also be run manually with `workflow_dispatch`.

See `docs/runbooks/codex-remote-devbox-release.md` and `docs/runbooks/multica-runtime-release.md` for version selection, local smoke tests, publication, manifest verification, and rollback guidance.

## Contributor Guidance

`AGENTS.md` is the canonical shared contributor and agent guidance. `CLAUDE.md` is a compatibility symlink to the same guidance for tools that still look for that path.

Meaningful image, build, publish, or repository convention changes should keep `README.md`, `AGENTS.md`, `docs/changelog.md`, and relevant ADRs or runbooks aligned.
