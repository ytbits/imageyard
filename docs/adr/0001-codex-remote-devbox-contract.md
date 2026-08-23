# ADR 0001: Codex Remote Devbox Image Contract

- Status: Accepted
- Date: 2026-08-22

## Context

Codex Desktop can open a remote project over SSH and start the Codex app server through that SSH session. ImageYard needs a reproducible, multi-architecture SSH devbox for that use case without coupling the public image to any particular deployment platform or network topology.

The image must provide a stable remote-user contract, accept credentials only at runtime, and publish immutable releases. It is distinct from the Multica Codex runtime, which runs a Multica daemon rather than accepting interactive SSH sessions.

## Decision

### Image and release identity

- Store the image definition and its assets under `codex-remote-devbox/`.
- Publish `ghcr.io/ytbits/codex-remote-devbox` for `linux/amd64` and `linux/arm64`.
- Use immutable tags in the form `codex-<CODEX_VERSION>-r<REVISION>`.
- Publish the initial release as `codex-0.149.0-r1`.
- Publish the state-mount bootstrap correction as current revision `codex-0.149.0-r2`.
- Reset the revision to `r1` when Codex changes. Increment the revision when packaging changes while the Codex version remains unchanged.
- Do not publish moving tags such as `latest` or `stable`.

### Runtime contract

- Build from `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`.
- Install `@openai/codex@0.149.0` exactly and expose it on the SSH login shell's `PATH`.
- Run `tini` and OpenSSH as the root container process, with SSH sessions entering as `codex` UID/GID `1000` using Bash.
- Listen for SSH on TCP port `2222`.
- Require explicit state mounts at `/home/codex` for user state and `/workspaces` for project checkouts. Each path must be a real, non-symlink directory and an exact mountpoint entry in `/proc/self/mountinfo`; an image-layer directory or a mount on only a parent path is rejected.
- Before changing either state mount, validate the fixed `codex` UID/GID and shell, both mountpoint types, both SSH inputs, every authorized public-key line, the Ed25519 host private key, and the effective OpenSSH configuration.
- Bootstrap only the two mount roots, never their descendants: conditionally set each root to UID/GID `1000`, set mode `0700`, require that exact postcondition, and then require `codex` to create and remove a randomized temporary probe.
- Do not seed, wipe, recursively change, or migrate existing state. Fail closed when a state root is missing, the wrong type, symlinked, not an exact mountpoint, read-only, or otherwise cannot satisfy the ownership, mode, and probe contract.
- Read authorized client keys from `/run/secrets/ssh-access/authorized_keys` and the Ed25519 host key from `/run/secrets/ssh-host/ssh_host_ed25519_key`.
- Accept one or more bare OpenSSH public-key lines in the authorized-keys input. Reject per-key options and non-public-key file formats.
- Fail closed when either required key is missing, empty, invalid, or unsafe to use. Do not generate an ephemeral host identity or log key material.
- Permit public-key authentication only. Disable root, password, keyboard-interactive, agent forwarding, X11 forwarding, remote forwarding, banners, and MOTD output. Permit local forwarding only to loopback destinations on the devbox.
- Do not start or expose a Codex app-server listener. Codex Desktop starts the app server through the SSH connection as described by the [Codex remote connections documentation](https://learn.chatgpt.com/docs/remote-connections).
- Keep the process chain as root `tini -g` to the root entrypoint to `exec` foreground OpenSSH. Forward termination signals to the process group so sshd and active sessions stop within the bounded shutdown interval.

### Tool and privilege boundary

- Include a lean general development toolset: Node/npm, Python with `venv` and `pip`, Git, Git LFS, GitHub CLI, OpenSSH, build-essential, curl, jq, ripgrep, fd, bubblewrap, and basic diagnostic utilities.
- Exclude Docker, Kubernetes tools, infrastructure CLIs, `nvm`, and `pyenv`.
- Do not require privileged mode, a Docker socket, or broad host-filesystem access beyond the documented key and state mounts.
- Grant `codex` full passwordless sudo. This is an explicit convenience exception to least privilege. Changes made through sudo affect only the container's writable layer and are not part of the immutable image contract; durable tool changes require a new image revision.

### Credential boundary

- Never bake Codex credentials, GitHub credentials, API tokens, SSH private keys, authorized client keys, host keys, or user configuration into the image or pass them as build arguments.
- Supply SSH access and host keys through the documented runtime files as read-only source mounts. Copy validated material into root-owned runtime files without modifying source bytes or metadata, writing key material into either state mount, or logging it.
- Authenticate interactively after connecting with `codex login --device-auth` and `gh auth login --git-protocol https`. Persisting `/home/codex` is the deployment operator's responsibility. Treat the files beneath `~/.codex` and `~/.config/gh` as credentials. See the [Codex authentication documentation](https://learn.chatgpt.com/docs/auth).

### Validation and publishing

- Keep validation and publishing in separate, image-specific workflows.
- Validate shell and workflow syntax, build and run both target platforms, exercise SSH authentication and negative cases, and inspect the image for the documented runtime contract.
- Use no-copy named volumes to exercise fresh root-owned mount bootstrap. Verify mandatory exact mountpoints, root-only normalization, nested metadata preservation, idempotent replacement, actual write probes, read-only and invalid-root failures, secret non-interference, and signal-driven shutdown on both architectures.
- Before publication, authenticate to GHCR and check the exact immutable tag. Repeat the check immediately before pushing. A present tag, an ambiguous response, or an unavailable registry fails closed.
- Publish a single multi-architecture OCI index under the immutable release tag and record the index and platform digests.

## Consequences

- Consumers receive a stable SSH user, filesystem, port, and key-file interface without any deployment-specific assumptions.
- The root SSH supervisor and passwordless sudo make this a trusted, single-user development image rather than a hardened multi-tenant sandbox.
- Consumers must provide both state mounts even for an otherwise ephemeral run. Persisting those mounts preserves authentication and project state across replacement.
- The image normalizes ownership and mode of each mount root to its fixed private contract. Existing descendants retain their content, ownership, permissions, timestamps, and links because bootstrap is deliberately nonrecursive.
- Base-image or package changes are traceable through OCI metadata and an incremented release revision even though those versions are intentionally omitted from the tag.
- A compromised SSH key grants an interactive `codex` session that can become root through sudo, so network reachability and runtime key distribution remain deployment responsibilities.
