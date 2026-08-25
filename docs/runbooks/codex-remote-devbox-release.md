# Codex Remote Devbox Release Runbook

This runbook covers building, validating, publishing, verifying, and rolling back the public Codex remote devbox image. It does not define a deployment platform or network topology.

## Current release contract

- Image: `ghcr.io/ytbits/codex-remote-devbox`
- Tag: `codex-0.149.0-r4`
- Build context: `codex-remote-devbox/`
- Dockerfile: `codex-remote-devbox/Dockerfile`
- Platforms: `linux/amd64`, `linux/arm64`
- Base: `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`
- Codex package: `@openai/codex@0.149.0`
- Docker packages: `docker-ce-cli=5:29.7.2-1~debian.12~bookworm`, `docker-buildx-plugin=0.36.1-1~debian.12~bookworm`, and `docker-compose-plugin=5.5.0-1~debian.12~bookworm`

Tags use `codex-<CODEX_VERSION>-r<REVISION>`. A Codex upgrade starts at `r1`; a packaging-only change for the same Codex version increments the revision. Never reuse or overwrite a published tag, and never publish a moving alias.

`codex-0.149.0-r1` remains the historical initial release. Revision `r2` added the mandatory state-mount bootstrap contract. Revision `r3` added only the pinned Docker clients and a fail-closed remote-Docker SSH bundle. Revision `r4` adds the supervised, Testcontainers-compatible local Unix bridge while preserving Codex `0.149.0`, the exact nine-file bundle, both state mounts, and the inbound SSH interface.

The runtime authorized-keys file accepts bare OpenSSH public-key lines only. Do not add per-key options or place a private key, known-hosts file, or another key format at that path.

## Runtime mount contract

Every start must provide five logical mount sources:

- a state mount at `/home/codex`;
- a state mount at `/workspaces`;
- the authorized-keys file at `/run/secrets/ssh-access/authorized_keys`, read-only;
- the Ed25519 host private key at `/run/secrets/ssh-host/ssh_host_ed25519_key`, read-only;
- the Docker-host source directory at `/run/secrets/docker-host`, read-only.

The two state paths must each be real, non-symlink directories and exact mountpoints. Mounting only `/home`, `/`, or another parent does not qualify. After validating identity, mount types, SSH inputs, and OpenSSH configuration, the entrypoint normalizes only each state-mount root to UID/GID `1000` and mode `0700`. It never recursively changes, seeds, wipes, or migrates descendants. It then creates and removes a randomized probe as `codex`; a missing, invalid, read-only, or otherwise unusable mount fails closed before sshd starts.

The Docker-host directory must contain these exact regular, non-symlink, nonempty files:

```text
docker_host
ssh_alias
ssh_host
ssh_port
ssh_user
ssh_client_ed25519_private_key
ssh_client_ed25519_fingerprint
ssh_host_ed25519_fingerprint
ssh_known_hosts
```

Use mode `0400` for `ssh_client_ed25519_private_key` and `0444` for the other inputs. `ssh_alias` must be exactly `docker-host`, and the generated OpenSSH stanza sets `HostKeyAlias docker-host` while retaining `ssh_host` as the real MagicDNS `HostName`. The private key must be Ed25519 and match its stored SHA-256 fingerprint. `ssh_known_hosts` must contain exactly one Ed25519 entry keyed by `docker-host` and match the stored host fingerprint. `docker_host` remains a required `ssh://docker-host/<absolute-socket-path>` consistency input; for example, `ssh://docker-host/Users/codex-smoke/.docker/run/docker.sock`. The image derives only the remote socket path from that URI and never hardcodes the Mac hostname or socket path.

Validated SSH-server inputs are copied to root-owned runtime files. The Docker client private key and known-hosts entry are copied on every start to `/run/codex-remote-devbox/docker-host/` as UID/GID `1000`, mode `0600`. The entrypoint generates the root-owned system `Host docker-host` configuration and a runtime sshd configuration with one `SetEnv` directive that injects exactly these values into authenticated interactive and command sessions:

```text
DOCKER_HOST=unix:///run/codex-remote-devbox/docker-bridge/docker.sock
TESTCONTAINERS_HOST_OVERRIDE=<validated ssh_host>
TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
```

The image does not modify `~/.ssh`, persist shared Docker credentials under `/home/codex`, set `DOCKER_CONTEXT`, alter source bytes or metadata, log values or fingerprints, or contact the Mac during startup validation. Direct `docker exec` or Kubernetes exec does not traverse sshd and is not evidence for this session environment; verify it through an authenticated SSH command or interactive session.

The image-owned bridge listens only at `/run/codex-remote-devbox/docker-bridge/docker.sock`. Its directory is `1000:1000` mode `0700`, and its Unix socket is `1000:1000` mode `0600`. For each accepted connection it starts one shell-free `/usr/bin/ssh` child with explicit system configuration, disabled TTY/forwarding/multiplexing, alias `docker-host`, and remote command `docker --host=unix://<validated-path> system dial-stdio`. It discards raw SSH stderr and relays concurrent HTTP, hijacked byte streams, and half-closes. A Mac or daemon outage fails that request without killing the bridge or delaying SSH readiness.

Operational boundary: this socket secures transport inside one Devbox; it does not partition the remote daemon. Every Devbox using this shared credential sees and contends for the same Mac daemon's container names and state, networks, images, volumes, build cache, CPU, and memory. Coordinate names and cleanup accordingly. Testcontainers and `docker run -p` publish on the Mac Docker host, not the Kubernetes Pod, and those ports may be reachable from LAN or tailnet peers depending on Docker Desktop, the Mac firewall, and tailnet policy. Revision `r4` adds no Kubernetes Docker TCP Service or listener; do not treat the local Unix socket as an isolation boundary.

Kubernetes mounts must make all nine source paths regular files at the exact names. A projected Secret's symlink front-end does not meet the non-symlink contract; mount each Secret item read-only at its final path with an explicit `subPath` file mount, with the private key at `0400` and the remaining inputs at `0444`. Together with the two state mounts and two SSH-server key mounts, that is thirteen `volumeMounts`, even though the Docker-host bundle is one logical source. Secret updates require Pod replacement: `subPath` mounts do not receive projected updates, and the entrypoint intentionally copies the validated key and pin only at container start.

GitOps adoption changes only the immutable image reference and rolls the Pod. Do not add deployment-level `DOCKER_HOST`, `DOCKER_CONTEXT`, or Testcontainers environment variables, a host socket mount, sidecar, init container, local daemon, or Kubernetes API dependency. The image generates the three client variables for SSH sessions from the existing bundle.

The runtime process chain is root `tini -g` to the validating entrypoint to a root Node supervisor. The supervisor validates or safely cleans the bridge socket path, starts the bridge as UID/GID `1000`, waits for the socket contract, and then starts foreground sshd as root. An unexpected bridge or sshd exit terminates its sibling and fails the container. Container shutdown and per-connection cleanup use bounded `TERM` then `KILL`. If socket identity is already compromised, the bridge reaps connection children and exits explicitly nonzero without allowing normal Node/libuv listener cleanup to unlink the replacement.

Accepted residual race: Node/libuv cannot close a Unix listener by inode. Detected compromise uses the explicit-exit path above; before ordinary graceful close, the bridge performs one synchronous metadata/inode check. A hostile same-UID process could still replace the path between that final `lstat` and libuv's unlink. Mode `0700` limits the runtime directory to the trusted `codex` user; treat that user and its full-sudo session as the security boundary, not as an adversarial tenant.

## Prepare a release

1. Start a `codex/` feature branch from current `main`.
2. Select the current non-prerelease Codex npm release and pin the exact version in the Dockerfile and workflow release constants.
3. Confirm that the package supports both target architectures.
4. Pin the exact Node image version and manifest-list digest. Record both in the Dockerfile, image contract, and release documentation.
5. Query Docker's official Bookworm repository for the current amd64 and arm64 candidates, verify the downloaded apt-key SHA-256, and pin the full Debian versions for the CLI, Buildx, and Compose packages.
6. Choose the tag revision according to the rule above and update every release reference together.
7. Update `README.md`, `AGENTS.md`, `docs/changelog.md`, this runbook, and the ADR if the durable contract changed.

Do not put credentials, local configuration, SSH keys, private hosts, or deployment-specific examples in the build context, documentation, labels, build arguments, or workflow logs.

## Run local validation

Run the repository checks from the repository root:

```bash
sh -n codex-remote-devbox/entrypoint.sh
bash -n codex-remote-devbox/smoke-test.sh
node --check codex-remote-devbox/docker-bridge.js
node --check codex-remote-devbox/docker-bridge-client-smoke.js
node --check codex-remote-devbox/supervisor.js
node --test codex-remote-devbox/docker-bridge.test.js
python3 -c 'compile(open("codex-remote-devbox/fake-docker-backend.py", encoding="utf-8").read(), "codex-remote-devbox/fake-docker-backend.py", "exec")'
git diff --check
```

The focused Node suite covers fixed argument construction, path rejection, Unix-socket metadata, concurrent binary and hijacked relays, offline request recovery, bounded child reaping, socket-identity failure, and safe stale-socket cleanup without using Docker or the real Mac. The full image smoke additionally runs a deterministic fake SSH server and `docker system dial-stdio` backend on each target architecture.

Build the local smoke-test image:

```bash
docker build \
  --file codex-remote-devbox/Dockerfile \
  --tag imageyard/codex-remote-devbox:smoke \
  codex-remote-devbox
```

Run the automated smoke test:

```bash
codex-remote-devbox/smoke-test.sh imageyard/codex-remote-devbox:smoke
```

The smoke test creates disposable named volumes with copy-up disabled, so fresh root-owned volume roots exercise the image bootstrap rather than inheriting the ownership of the baked directories. For an equivalent offline-target manual start, create temporary keys, a complete Docker-host bundle, and two named volumes:

```bash
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-devbox-local.XXXXXX")"
home_volume="codex-devbox-home-$$"
workspaces_volume="codex-devbox-workspaces-$$"
container_name="codex-devbox-local-$$"

mkdir -p "$fixture_dir/access" "$fixture_dir/host" "$fixture_dir/docker-host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/client_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/docker_client_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/docker_target_host_key"
cp "$fixture_dir/client_key.pub" "$fixture_dir/access/authorized_keys"
cp "$fixture_dir/docker_client_key" \
  "$fixture_dir/docker-host/ssh_client_ed25519_private_key"
ssh-keygen -l -E sha256 -f "$fixture_dir/docker_client_key.pub" \
  | awk '{print $2}' > "$fixture_dir/docker-host/ssh_client_ed25519_fingerprint"
ssh-keygen -l -E sha256 -f "$fixture_dir/docker_target_host_key.pub" \
  | awk '{print $2}' > "$fixture_dir/docker-host/ssh_host_ed25519_fingerprint"
printf '%s %s\n' docker-host \
  "$(cut -d ' ' -f 1-2 "$fixture_dir/docker_target_host_key.pub")" \
  > "$fixture_dir/docker-host/ssh_known_hosts"
printf '%s\n' 'ssh://docker-host/Users/codex-smoke/.docker/run/docker.sock' \
  > "$fixture_dir/docker-host/docker_host"
printf '%s\n' docker-host > "$fixture_dir/docker-host/ssh_alias"
printf '%s\n' docker.invalid > "$fixture_dir/docker-host/ssh_host"
printf '%s\n' 22 > "$fixture_dir/docker-host/ssh_port"
printf '%s\n' codex-smoke > "$fixture_dir/docker-host/ssh_user"
chmod 0444 "$fixture_dir/access/authorized_keys" "$fixture_dir/docker-host"/*
chmod 0400 \
  "$fixture_dir/client_key" \
  "$fixture_dir/host/ssh_host_ed25519_key" \
  "$fixture_dir/docker-host/ssh_client_ed25519_private_key"

docker volume create "$home_volume"
docker volume create "$workspaces_volume"
docker run --detach \
  --name "$container_name" \
  --publish 127.0.0.1:2222:2222 \
  --mount "type=volume,src=${home_volume},dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=${workspaces_volume},dst=/workspaces,volume-nocopy" \
  --mount "type=bind,src=${fixture_dir}/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
  --mount "type=bind,src=${fixture_dir}/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
  --mount "type=bind,src=${fixture_dir}/docker-host,dst=/run/secrets/docker-host,readonly" \
  imageyard/codex-remote-devbox:smoke

for attempt in $(seq 1 60); do
  if ssh-keyscan -T 2 -p 2222 -t ed25519 127.0.0.1 \
    > "$fixture_dir/known_hosts" 2>/dev/null; then
    break
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$container_name")" != true ]; then
    docker logs "$container_name"
    exit 1
  fi
  sleep 0.5
done
[ -s "$fixture_dir/known_hosts" ] || {
  docker logs "$container_name"
  exit 1
}
```

`volume-nocopy` prevents Docker from copying the baked directory metadata into a new empty volume. Ordinary existing named volumes also satisfy the exact-mountpoint requirement. Confirm bootstrap and connect:

```bash
docker exec "$container_name" stat -c '%u:%g %a %n' /home/codex /workspaces
ssh \
  -F /dev/null \
  -p 2222 \
  -i "$fixture_dir/client_key" \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=${fixture_dir}/known_hosts" \
  codex@127.0.0.1
```

Both `stat` rows must report `1000:1000 700`. The deliberately unreachable `docker.invalid` target must not delay SSH readiness. Inside the SSH session, `DOCKER_HOST` must be the local bridge URI, `TESTCONTAINERS_HOST_OVERRIDE` must equal the validated `ssh_host`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` must be `/var/run/docker.sock`, and `DOCKER_CONTEXT` must be absent. A Docker command is expected to fail promptly until the real Mac becomes reachable, while a later request must be able to recover without restarting the container. Remove the disposable container and volumes after the check; retaining either named volume intentionally retains its state.

Before publication, repeat the build and smoke test on a native ARM64 host rather than through emulation:

```bash
docker buildx build \
  --platform linux/arm64 \
  --load \
  --file codex-remote-devbox/Dockerfile \
  --tag imageyard/codex-remote-devbox:smoke-arm64 \
  codex-remote-devbox

codex-remote-devbox/smoke-test.sh imageyard/codex-remote-devbox:smoke-arm64
```

The smoke test must use temporary Ed25519 client and host keys and must verify at least:

- trusted-key SSH succeeds while unknown-key, password, root, and missing-key cases fail;
- starts without both exact state mountpoints fail, while fresh no-copy named volumes bootstrap their roots to UID/GID `1000`, mode `0700`, and actual `codex` writability;
- missing, regular-file, symlinked, parent-only, read-only, and otherwise invalid state roots fail before SSH starts;
- bootstrap is idempotent across replacement and preserves nested content, ownership, modes, timestamps, symlinks, and hard links;
- temporary write probes are removed, and failed secret validation leaves both state mounts unchanged;
- SSH source files retain their bytes and metadata and never appear in state, image layers, history, or logs;
- the Docker CLI reports `29.7.2`, Buildx reports `0.36.1`, Compose reports `5.5.0`, and `dpkg-query` reports the exact pinned Bookworm package versions;
- Docker Engine, `dockerd`, `containerd`, DinD, Podman, nerdctl, mounted host/daemon sockets, and Docker daemon listeners are absent; the only local Docker endpoint is the image-owned bridge Unix socket;
- every missing, empty, symlinked, malformed, wrong-alias, bad-key, bad-fingerprint, or bad-known-host Docker bundle case fails before SSH and before state mutation;
- the valid offline bundle reaches SSH readiness, preserves all source bytes and metadata, creates only UID/GID `1000` mode `0600` runtime key/pin copies, and leaks no value, fingerprint, key, or raw SSH error into logs, image layers, `/home/codex`, or `/workspaces`;
- the bridge directory is `1000:1000` mode `0700`, the socket is `1000:1000` mode `0600`, both are non-symlink objects with monitored identity, unsafe path occupants fail closed, and verified stale sockets are removed without deleting replacements;
- both interactive and command SSH sessions receive the exact local `DOCKER_HOST`, validated-host `TESTCONTAINERS_HOST_OVERRIDE`, and `/var/run/docker.sock` override while `DOCKER_CONTEXT` is absent; direct exec remains outside this sshd contract;
- explicit system SSH configuration defeats an adversarial Home `Host docker-host` stanza, and effective `ssh -G -F /etc/ssh/ssh_config docker-host` contains the validated hostname, `HostKeyAlias docker-host`, `ConnectTimeout 10`, and other fail-closed options;
- a deterministic fake SSH/dial-stdio backend proves concurrent `/_ping`, Docker CLI and Node clients observing the same daemon identity, one fixed `/usr/bin/ssh` argv per connection, binary hijack and half-close relay, stderr isolation, prompt offline failure, and later-request recovery without the user's Mac;
- the SSH session is UID/GID `1000` and Bash is the login shell;
- `sudo -n id -u` returns `0`;
- `codex --version` reports `0.149.0` and `codex app-server --help` succeeds;
- the lean toolset and pinned Docker clients are present while daemon, Kubernetes, and infrastructure tooling is absent;
- SSH is the only TCP listener and listens only on `2222`; the bridge is AF_UNIX-only, no login banner is emitted, and no Codex app server is prestarted;
- the container starts without privileged mode, a mounted host/daemon Docker socket, or mounts beyond the documented Secret and state paths;
- the image and its history contain no test key or token marker;
- reusing the same externally supplied host key preserves the SSH fingerprint;
- mounted home and workspace directories preserve state across container replacement;
- unexpected bridge or sshd failure terminates the sibling and exits nonzero; `SIGTERM` reaches the `tini -g`/entrypoint/supervisor service tree, stops active sessions and per-connection SSH children, and leaves no owned socket or orphan process after bounded `TERM`/`KILL` cleanup.

Run or inspect the validation workflow before publishing. It builds and smoke-tests both `linux/amd64` and `linux/arm64`; the release is not ready until both jobs pass. Before the first release of a new architecture-sensitive package, also perform one smoke test on a native ARM64 host.

## Verify with Codex Desktop

Before publication, start the local test container with the documented key mounts and a loopback-only mapping such as `127.0.0.1:2222:2222`. Create a concrete OpenSSH alias such as:

```sshconfig
Host codex-devbox-local
  HostName 127.0.0.1
  Port 2222
  User codex
  IdentityFile /absolute/path/to/codex-devbox-client
```

Replace `IdentityFile` with an absolute path to the test client key. For the disposable fixture above, resolve and use the absolute value of `$fixture_dir/client_key`; copy it to a durable private path first if the alias must outlive that fixture.

Then verify:

1. `ssh codex-devbox-local` succeeds without unexpected stdout from shell startup.
2. Codex Desktop discovers the concrete alias and opens a repository beneath `/workspaces`.
3. A task can read, edit, run a command, request approval, and reconnect.
4. The remote login shell resolves `codex` without an interactive-shell-only PATH modification.

If authentication is needed, perform it inside the trusted SSH session with `codex login --device-auth` and `gh auth login --git-protocol https`. Do not copy token files into the image.

## Publish

1. Push the focused feature branch and open a draft pull request.
2. Require the image-specific validation workflow to pass.
3. Review the resolved base digest, exact Codex version, release tag, workflow permissions, and changed paths.
4. Merge only after separate approval. A qualifying merge to `main` invokes the image-specific publish workflow; a manual dispatch must also target `main`.
5. The publish workflow must complete the reusable validation job, then authenticate to GHCR, verify that the exact tag does not exist before its release build, check the tag again immediately before the push, and publish one multi-architecture index. Only an exact registry not-found permits publication.

The target for this release is:

```text
ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r4
```

## Verify publication

Inspect the remote OCI index:

```bash
docker buildx imagetools inspect \
  ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r4
```

Record in the release or pull-request evidence:

- the source Git revision;
- the OCI index digest;
- the `linux/amd64` manifest digest;
- the `linux/arm64` manifest digest;
- the config digest for each platform manifest;
- confirmation that no moving tags were published.

Pull and smoke-test the exact published index digest on each available native platform. Confirm its OCI labels identify the source repository, source revision, base image, exact Codex version, exact Docker packages, and apt-key checksum. Anonymous inspection and pull must work without registry credentials.

GHCR may briefly return a read error immediately after accepting a new tag. Post-push verification uses bounded read-only retries, first proves that the tag resolves to the action's pushed index digest, and then derives every platform and config digest through that immutable reference. The retry loop never repeats the push. If it exhausts or any digest differs, preserve the published tag, inspect it independently, and do not rerun a publishing attempt against the same revision.

Docker build contexts are sent from the devbox client to the Mac engine. Bind mounts are different: the daemon resolves their source paths on the Mac, so a Compose entry such as `.:/app` does not mount the devbox's `/workspaces` directory. Build the content into an image, synchronize it to the Mac, or use another explicit remote-development workflow.

## Rollback and failed releases

- Roll back a consumer by selecting an older known-good immutable tag or, preferably, its recorded digest.
- Never delete or overwrite the defective tag as part of normal remediation.
- When Codex remains `0.149.0`, fix a defect in `r4` with a new `codex-0.149.0-r5`; continue incrementing the revision for later packaging fixes.
- If a workflow cannot prove whether the target tag exists, stop. Resolve registry authentication or availability and rerun the complete publish workflow.
- If publication partially succeeds, inspect the registry before retrying. Any existing target tag requires a new revision.
