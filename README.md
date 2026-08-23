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
│   ├── entrypoint.sh
│   ├── smoke-test.sh
│   └── sshd_config
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

- Image: `ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r2`
- Dockerfile and build context: `codex-remote-devbox/Dockerfile` and `codex-remote-devbox/`
- Base: `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`
- Codex CLI: `@openai/codex@0.149.0`
- Published platforms: `linux/amd64`, `linux/arm64`
- SSH contract: port `2222`, user `codex` with UID/GID `1000` and Bash
- Required state mountpoints: `/home/codex` and `/workspaces`
- Runtime access key: `/run/secrets/ssh-access/authorized_keys`
- Runtime host key: `/run/secrets/ssh-host/ssh_host_ed25519_key`

Both state paths must be explicit mountpoints; image-layer directories or a mount on only a parent path do not satisfy the contract. After validating the fixed identity, mount types, runtime keys, and OpenSSH configuration, the root entrypoint bootstraps only the two mount roots to UID/GID `1000` and mode `0700`, then verifies that `codex` can create and remove a temporary probe. Bootstrap is nonrecursive: it never seeds, wipes, changes, or migrates existing descendants. A missing, non-directory, symlinked, non-mountpoint, read-only, or otherwise unusable state root fails closed before SSH starts.

The authorized-keys file accepts one or more bare OpenSSH public-key lines; per-key options are intentionally not accepted. Runtime key sources are treated as read-only inputs, copied into root-owned runtime files, and never written into either state mount. The root process chain remains `tini -g` to the entrypoint to foreground OpenSSH; authenticated sessions enter as `codex`, and termination signals are forwarded through that chain for bounded shutdown. SSH is public-key-only and fails closed when either runtime key is missing or invalid. The image grants `codex` full passwordless sudo as an explicit single-user development convenience, but it does not require privileged mode, a Docker socket, or broad host-filesystem access beyond the documented key and state mounts.

The image includes a lean Node, Python, Git, GitHub CLI, SSH, and build toolset. It deliberately excludes Docker, Kubernetes tools, infrastructure CLIs, `nvm`, and `pyenv`. No Codex, GitHub, API, SSH, or user credentials are included in the image. Authenticate after connecting with `codex login --device-auth` and `gh auth login --git-protocol https`; persist both required state mountpoints across replacement when their contents must survive.

Codex Desktop starts its app server through the SSH connection, so the image does not start or expose an app-server listener. See the official [remote connections](https://learn.chatgpt.com/docs/remote-connections) and [authentication](https://learn.chatgpt.com/docs/auth) documentation.

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
