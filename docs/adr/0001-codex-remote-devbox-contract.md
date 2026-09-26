# ADR 0001: Codex Remote Devbox Image Contract

- Status: Accepted
- Date: 2026-08-22
- Last updated: 2026-09-26

## Context

Codex Desktop can open a remote project over SSH and start the Codex app server through that SSH session. ImageYard needs a reproducible, multi-architecture SSH devbox for that use case without coupling the public image to any particular deployment platform or network topology.

The image must provide a stable remote-user contract, accept credentials only at runtime, and publish immutable releases. It is distinct from the Multica Codex runtime, which runs a Multica daemon rather than accepting interactive SSH sessions.

## Decision

### Image and release identity

- Store the image definition and its assets under `codex-remote-devbox/`.
- Publish `ghcr.io/ytbits/codex-remote-devbox` for `linux/amd64` and `linux/arm64`.
- Use immutable tags in the form `codex-<CODEX_VERSION>-r<REVISION>`.
- Publish the initial release as `codex-0.149.0-r1`.
- Publish the state-mount bootstrap correction as revision `codex-0.149.0-r2`.
- Publish the remote-Docker client layer as revision `codex-0.149.0-r3`, without changing Codex or any `r2` state, SSH-server, process, signal, or no-init-container behavior.
- Publish the supervised, Testcontainers-compatible Unix bridge as revision `codex-0.149.0-r4`, preserving Codex `0.149.0`, the exact nine-file Docker-host input contract, and the existing state and inbound-SSH interfaces.
- Publish automatic runtime GHCR client authentication as revision `codex-0.149.0-r5`, preserving Codex, the remote-Docker bridge, both state mounts, and the inbound-SSH interface.
- Upgrade Codex to `0.157.1` as current release `codex-0.157.1-r1`, preserving the `0.149.0-r5` runtime contracts, pinned Node base, and pinned Docker packages.
- Reset the revision to `r1` when Codex changes. Increment the revision when packaging changes while the Codex version remains unchanged.
- Do not publish moving tags such as `latest` or `stable`.

### Runtime contract

- Build from `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`.
- Install `@openai/codex@0.157.1` exactly and expose it on the SSH login shell's `PATH`.
- Run root `tini -g` to the validating entrypoint to an image-owned root supervisor. Run the Docker bridge as `codex` UID/GID `1000`, run OpenSSH as root, and enter authenticated sessions as `codex` using Bash.
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
- After validation and state bootstrap, have the supervisor prepare the private bridge runtime directory, remove only a verified stale Unix socket, start the bridge as UID/GID `1000`, wait for its ready socket, and then start foreground sshd as root. Treat an unexpected bridge or sshd exit as fatal, terminate the sibling, and exit nonzero. Forward container termination through bounded `TERM` then `KILL` cleanup for both services and all per-connection SSH children.
- Require the Docker-host bundle at `/run/secrets/docker-host` with the exact files `docker_host`, `ssh_alias`, `ssh_host`, `ssh_port`, `ssh_user`, `ssh_client_ed25519_private_key`, `ssh_client_ed25519_fingerprint`, `ssh_host_ed25519_fingerprint`, and `ssh_known_hosts`. Each input is a regular, non-symlink, nonempty read-only source.
- Fix both the image-owned SSH alias and `HostKeyAlias` to `docker-host`; keep `HostName` as the separately configured MagicDNS host. Validate safe field syntax, an Ed25519 client key and its derived fingerprint, and exactly one Ed25519 known-hosts entry keyed by `docker-host` and matching the stored host fingerprint. Never log those values.
- Copy the Docker client private key and known-hosts entry on every start to `/run/codex-remote-devbox/docker-host/` as UID/GID `1000`, mode `0600`. Do not persist them in `/home/codex`, change `~/.ssh`, or affect the legacy user alias `docker-mac`.
- Generate a root-owned system `Host docker-host` stanza with `HostKeyAlias docker-host` and exact identity, pinning, batch, `ConnectTimeout 10`, public-key-only, strict-checking, Ed25519-only, no-update, and no-agent-forwarding options. Validate effective OpenSSH resolution with an explicit `-F /etc/ssh/ssh_config` without network access or output, so user-controlled Home configuration cannot override the image contract.
- Continue validating `docker_host` as an `ssh://docker-host/<absolute-socket-path>` URI for bundle consistency. Derive the remote Docker Unix socket path from it; do not export the SSH URI as the client endpoint.
- Own the local bridge endpoint at `/run/codex-remote-devbox/docker-bridge/docker.sock`. Require a real, non-symlink directory owned `1000:1000` mode `0700` and a real Unix socket owned `1000:1000` mode `0600`. Reject unsafe or live existing objects, remove only an inode-checked stale socket, monitor directory and socket identity, and fail closed on replacement without unlinking an attacker-controlled object. After bounded connection-child cleanup on detected identity compromise, explicitly exit the bridge nonzero so normal Node/libuv teardown cannot close the listener and unlink the replacement. Open no bridge TCP listener.
- For every accepted local connection, spawn one `/usr/bin/ssh` child without a shell, with a minimal fixed environment and a fixed argument structure selecting the system SSH config, disabling TTY, forwarding, and multiplexing, targeting `docker-host`, and invoking `docker --host=unix://<validated-path> system dial-stdio`. Discard raw SSH stderr, relay bytes in both directions for concurrent HTTP, hijacked streams, and half-closes, tolerate expected disconnect errors, and reap children with bounded `TERM` then `KILL`. Treat an offline Mac or unavailable Docker daemon as a request failure, not a bridge or SSH-readiness failure.
- Copy the immutable sshd configuration to `/run` and append one `SetEnv` directive containing exactly `DOCKER_HOST=unix:///run/codex-remote-devbox/docker-bridge/docker.sock`, `TESTCONTAINERS_HOST_OVERRIDE=<validated ssh_host>`, and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`. Validate the runtime file with `sshd -t` and run foreground sshd with it. Do not set `DOCKER_CONTEXT`; direct container exec does not receive this sshd session contract.
- Treat Mac reachability and Docker Desktop availability as runtime concerns, not startup gates. A syntactically valid offline target still permits SSH readiness and later recovery without replacing the devbox.
- Require `/run/secrets/ghcr/ghcr_username` and `/run/secrets/ghcr/ghcr_pat` as root-owned regular, non-symlink, nonempty source files with modes `0444` and `0400`. Validate their syntax without printing values, then copy them on every start to the exact UID/GID `1000` mode-`0700` runtime directory `/run/codex-remote-devbox/ghcr/` as mode-`0600` files. Never persist the PAT or a derived auth value in either state mount.
- Install a root-owned Docker credential helper that serves the runtime credential only for normalized `ghcr.io` requests made as UID/GID `1000`. Reject writes, erases, unsupported hosts, unsafe metadata, malformed values, and oversized input generically. The helper is host-scoped, not capability-scoped: it enables every GHCR operation granted by the supplied PAT and package ACLs.
- Atomically manage only `credHelpers["ghcr.io"]="codex-ghcr"` in a codex-owned, non-symlink, single-link `~/.docker/config.json`, preserving all unrelated fatal-UTF-8 valid JSON when the configuration has a single writer. Serialize image-owned public actions through a fixed runtime kernel lock; use single-link mode-`0600` same-directory temporary files, full identity checks, file/directory sync, and safe locked recovery of exact image-named files left by a killed image-owned writer. Reject unsafe stale objects and differently managed GHCR helpers. The lock is intentionally image-private: uncooperative Docker or same-UID writers do not participate, and ordinary POSIX rename cannot close the post-identity-check/pre-rename race without a shared lock or a materially more complex transaction protocol. Run startup enable before sshd, and require operators to quiesce every external Docker-config writer before manual enable, scrub, or disable. First enable must preserve any legacy `auths["ghcr.io"]`; expose an explicit idempotent scrub operation for that exact entry only after helper-backed acceptance, and an explicit idempotent disable operation that removes only the exact image-managed mapping for rollback.

### Tool and privilege boundary

- Include a lean general development toolset: Node/npm, Python with `venv` and `pip`, Git, Git LFS, GitHub CLI, OpenSSH, build-essential, curl, jq, ripgrep, fd, bubblewrap, and basic diagnostic utilities.
- From Docker's official Debian repository, install only exact pinned `docker-ce-cli`, `docker-buildx-plugin`, and `docker-compose-plugin` packages. Verify the repository key checksum and package versions for both architectures.
- Exclude Docker Engine, `dockerd`, `containerd`, DinD, Podman, nerdctl, Kubernetes tools, infrastructure CLIs, `nvm`, and `pyenv`.
- Do not require privileged mode, mount a host or daemon Docker socket, expose a daemon listener, or use broad host-filesystem access beyond the documented state and read-only Secret mounts. The image-owned private Unix bridge is a client transport, not a Docker daemon.
- Grant `codex` full passwordless sudo. This is an explicit convenience exception to least privilege. Changes made through sudo affect only the container's writable layer and are not part of the immutable image contract; durable tool changes require a new image revision.

### Credential boundary

- Never bake Codex credentials, GitHub credentials, API tokens, SSH private keys, authorized client keys, host keys, or user configuration into the image or pass them as build arguments.
- Supply SSH access and host keys through the documented runtime files as read-only source mounts. Copy validated material into root-owned runtime files without modifying source bytes or metadata, writing key material into either state mount, or logging it.
- Supply GHCR credentials only through the two documented runtime files. Store only their non-secret per-registry helper mapping in Home; never store the PAT, helper response, a base64 `auth`, or a backup containing those values there. A GHCR outage or revoked token affects registry commands but does not gate SSH readiness.
- Treat `codex` and its full-sudo session as able to extract any usable GHCR credential. The helper prevents accidental persistence and limits registry matching; it is not a defense against trusted-user exfiltration, a pull-only enforcement point, or a per-Devbox isolation boundary.
- Accept the narrowly documented same-UID writer race: `codex-ghcr-auth` detects replacements that happen before its final identity check, but an uncooperative replacement in the remaining check-to-rename window can be overwritten. The boot path has no exposed user session at that point; manual operations are maintenance actions and must quiesce external writers. The image-owned `flock` and crash recovery cover only cooperating image-owned actions.
- Authenticate interactively after connecting with `codex login --device-auth` and `gh auth login --git-protocol https`. Persisting `/home/codex` is the deployment operator's responsibility. Treat the files beneath `~/.codex` and `~/.config/gh` as credentials. See the [Codex authentication documentation](https://learn.chatgpt.com/docs/auth).

### Validation and publishing

- Keep validation and publishing in separate, image-specific workflows.
- Validate shell and workflow syntax, run focused Node bridge/supervisor and GHCR helper/configuration tests, build and run both target platforms, exercise SSH authentication and negative cases, and inspect the image for the documented runtime contract.
- Exercise app-server stdio over authenticated SSH with a bounded `initialize`/`initialized` exchange followed by `config/read`. Require the exact Codex version, `codexHome=/home/codex/.codex`, Unix/Linux platform, a successful configuration response without logging its values, clean shutdown after input closes, and no additional TCP listener; repeat against fresh and reused Home fixtures. Keep the pre-publication Codex Desktop connection, task, and reconnect acceptance check.
- Use no-copy named volumes to exercise fresh root-owned mount bootstrap. Verify mandatory exact mountpoints, root-only normalization, nested metadata preservation, idempotent replacement, actual write probes, read-only and invalid-root failures, secret non-interference, and signal-driven shutdown on both architectures.
- Before publication, authenticate to GHCR and check the exact immutable tag. Repeat the check immediately before pushing. A present tag, an ambiguous response, or an unavailable registry fails closed.
- Publish a single multi-architecture OCI index under the immutable release tag and record the index and platform digests. Use bounded read-only retries for transient post-push registry visibility, while anchoring every inspection to the pushed index digest and never retrying the push.
- Verify the Docker package outputs, runtime bundle failure cases, source immutability, bridge directory/socket ownership and modes, fixed SSH argv, concurrent HTTP and raw hijack relay, child cleanup, stale-socket and service-failure handling, exact SSH-session environment, helper protocol, authenticated Docker client requests, hostile Home configuration, legacy-auth preservation/scrub/rollback, GHCR source and runtime metadata, offline-target readiness and request failure, daemon exclusions, and absence of secret material on both native architectures. Use a deterministic fake SSH/dial-stdio backend rather than a live Mac or real registry credential in CI.

## Consequences

- Consumers receive a stable SSH user, filesystem, port, and key-file interface without any deployment-specific assumptions.
- The root SSH supervisor and passwordless sudo make this a trusted, single-user development image rather than a hardened multi-tenant sandbox.
- Consumers must provide both state mounts even for an otherwise ephemeral run. Persisting those mounts preserves authentication and project state across replacement.
- The image normalizes ownership and mode of each mount root to its fixed private contract. Existing descendants retain their content, ownership, permissions, timestamps, and links because bootstrap is deliberately nonrecursive.
- Base-image or package changes are traceable through OCI metadata and an incremented release revision even though those versions are intentionally omitted from the tag.
- The `0.157.1` upstream native Codex payload is larger than `0.149.0`, increasing image storage and transfer requirements. This is accepted for the stable CLI upgrade; it does not change the startup process or permit a prestarted app-server TCP listener.
- Docker and Testcontainers clients use the local image-owned Unix endpoint, which relays each connection to the pinned remote Mac engine through SSH. Build contexts are transferred to that engine, while bind-mount source paths resolve on the Mac and are not devbox `/workspaces` paths; the Testcontainers socket override presents the remote bind target as `/var/run/docker.sock`.
- The local Unix endpoint is a secured transport, not a tenancy or resource-isolation boundary. All Devboxes using the shared Docker-host credential operate on the same Mac daemon: container names and state, networks, images, volumes, build cache, and CPU/memory contention are daemon-wide. Testcontainers and explicitly published (`-p`) ports bind on the Mac Docker host and may be reachable by LAN or tailnet peers as allowed by Docker Desktop, host-firewall, and tailnet policy. Revision `r5` introduces no Kubernetes-side Docker TCP endpoint, and separate client credentials cannot hide already-cached private image layers from another client of the same daemon.
- Rollback from `r5` requires configuration staging while the helper still exists. Before a legacy-auth scrub, disable the exact helper mapping and the preserved legacy entry resumes. After scrub, retain `r5` helper/Vault continuity until a replacement client credential path is established; rolling directly to `r4` would leave the non-secret mapping unusable or leave the client without GHCR authentication.
- Node/libuv has no inode-addressed Unix-listener close operation. A detected compromise takes the explicit-exit path and preserves the replacement; ordinary graceful shutdown synchronously revalidates identity immediately before close. A same-UID process could still race replacement between that final `lstat` and libuv's pathname unlink. The private `0700` codex-owned directory narrows access but does not remove this residual TOCTOU; it is accepted under the image's trusted single-user `codex` model.
- A compromised SSH key grants an interactive `codex` session that can become root through sudo, so network reachability and runtime key distribution remain deployment responsibilities.
