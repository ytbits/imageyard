# Codex Remote Devbox Release Runbook

This runbook covers building, validating, publishing, verifying, and rolling back the public Codex remote devbox image. It does not define a deployment platform or network topology.

## Current release contract

- Image: `ghcr.io/ytbits/codex-remote-devbox`
- Tag: `codex-0.149.0-r5`
- Build context: `codex-remote-devbox/`
- Dockerfile: `codex-remote-devbox/Dockerfile`
- Platforms: `linux/amd64`, `linux/arm64`
- Base: `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`
- Codex package: `@openai/codex@0.149.0`
- Docker packages: `docker-ce-cli=5:29.7.2-1~debian.12~bookworm`, `docker-buildx-plugin=0.36.1-1~debian.12~bookworm`, and `docker-compose-plugin=5.5.0-1~debian.12~bookworm`

Tags use `codex-<CODEX_VERSION>-r<REVISION>`. A Codex upgrade starts at `r1`; a packaging-only change for the same Codex version increments the revision. Never reuse or overwrite a published tag, and never publish a moving alias.

`codex-0.149.0-r1` remains the historical initial release. Revision `r2` added the mandatory state-mount bootstrap contract. Revision `r3` added only the pinned Docker clients and a fail-closed remote-Docker SSH bundle. Revision `r4` added the supervised, Testcontainers-compatible local Unix bridge. Revision `r5` adds runtime GHCR client authentication while preserving Codex `0.149.0`, the exact nine-file Docker-host bundle, both state mounts, the bridge, and the inbound SSH interface.

The runtime authorized-keys file accepts bare OpenSSH public-key lines only. Do not add per-key options or place a private key, known-hosts file, or another key format at that path.

## Runtime mount contract

Every start must provide six logical mount sources:

- a state mount at `/home/codex`;
- a state mount at `/workspaces`;
- the authorized-keys file at `/run/secrets/ssh-access/authorized_keys`, read-only;
- the Ed25519 host private key at `/run/secrets/ssh-host/ssh_host_ed25519_key`, read-only;
- the Docker-host source directory at `/run/secrets/docker-host`, read-only;
- the GHCR credential source directory at `/run/secrets/ghcr`, read-only.

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

The GHCR directory must expose exactly these two required source paths as root-owned regular, non-symlink, nonempty files:

```text
/run/secrets/ghcr/ghcr_username  # mode 0444
/run/secrets/ghcr/ghcr_pat       # mode 0400
```

The image validates a GitHub-compatible username and a printable single-line token without logging either value. It copies both on every start to `/run/codex-remote-devbox/ghcr/`, which is UID/GID `1000` mode `0700`; the exact runtime files `ghcr_username` and `ghcr_pat` are UID/GID `1000` mode `0600`. Source bytes and metadata remain unchanged. The PAT, helper response, base64 auth, and backups containing them must never enter `/home/codex`, `/workspaces`, image layers, environment variables, arguments, or logs.

Startup runs `codex-ghcr-auth enable` as `codex` before sshd accepts a session. It creates or atomically updates `~/.docker/config.json` to contain only the managed non-secret mapping `credHelpers["ghcr.io"]="codex-ghcr"`, while preserving every unrelated valid JSON field and any existing `auths["ghcr.io"]` under this single-writer startup contract. The `.docker` directory becomes mode `0700` and the config becomes mode `0600`; invalid UTF-8/JSON, symlinks, hardlinks, wrong ownership, invalid `auths`/`credHelpers` sections, a differently managed GHCR helper, and unsafe file types fail closed. Every image-owned public action takes an exclusive kernel `flock` on `/run/codex-remote-devbox/ghcr-auth.lock`, a UID/GID `1000`, single-link, mode-`0600` runtime file. Under that lock, writes use a same-directory single-link mode-`0600` temporary file, file `fsync`, full identity revalidation, atomic rename, and directory `fsync`. A later transaction removes only an exact, safely validated image-named temporary file left by a killed image-owned writer; unsafe or changed stale evidence fails closed rather than being followed, overwritten, or deleted.

This lock is not a general Docker-config transaction lock: `docker login`, `docker logout`, third-party tools, and arbitrary editors do not honor it. A replacement before the final identity check is rejected, but POSIX rename has a residual check-to-rename window in which an uncooperative writer can be overwritten. Before any manual `enable`, `scrub-legacy-auth`, or `disable`, stop or coordinate all sessions and automation that could write `/home/codex/.docker/config.json`; do not run those operations concurrently with Docker login/logout or direct config edits. There is no reliable process-name check for every possible writer, so this is an explicit operator maintenance gate, not an inferred safety check.

Docker gives the per-registry helper precedence over a legacy inline GHCR auth. After a helper-backed private pull or push succeeds, remove only that legacy entry on each Home PVC with the explicit, idempotent command:

```bash
codex-ghcr-auth scrub-legacy-auth
```

Do not run this automatically or before acceptance. For rollback preparation, the explicit, idempotent `codex-ghcr-auth disable` removes only an exact image-managed helper mapping. It leaves unrelated configuration and any legacy auth untouched and fails rather than overwrite or remove a different helper value. `codex-ghcr-auth enable` restores the exact managed mapping.

`docker-credential-codex-ghcr` serves the runtime credential only for `ghcr.io` and rejects helper `store`/`erase` operations. It enables every registry operation allowed by the supplied PAT and package ACLs, including push when granted; it is not a pull-only control. A revoked token or GHCR outage fails the registry command without blocking SSH readiness. Because `codex` has full sudo and must be able to pass the credential to Docker, code running as this trusted user can deliberately extract it. This design prevents accidental persistent storage and limits registry matching; it does not prevent malicious exfiltration or provide per-Devbox isolation.

Validated SSH-server inputs are copied to root-owned runtime files. The Docker client private key and known-hosts entry are copied on every start to `/run/codex-remote-devbox/docker-host/` as UID/GID `1000`, mode `0600`. The entrypoint generates the root-owned system `Host docker-host` configuration and a runtime sshd configuration with one `SetEnv` directive that injects exactly these values into authenticated interactive and command sessions:

```text
DOCKER_HOST=unix:///run/codex-remote-devbox/docker-bridge/docker.sock
TESTCONTAINERS_HOST_OVERRIDE=<validated ssh_host>
TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
```

The image does not modify `~/.ssh`, persist shared Docker credentials under `/home/codex`, set `DOCKER_CONTEXT`, alter source bytes or metadata, log values or fingerprints, or contact the Mac during startup validation. Direct `docker exec` or Kubernetes exec does not traverse sshd and is not evidence for this session environment; verify it through an authenticated SSH command or interactive session.

The image-owned bridge listens only at `/run/codex-remote-devbox/docker-bridge/docker.sock`. Its directory is `1000:1000` mode `0700`, and its Unix socket is `1000:1000` mode `0600`. For each accepted connection it starts one shell-free `/usr/bin/ssh` child with explicit system configuration, disabled TTY/forwarding/multiplexing, alias `docker-host`, and remote command `docker --host=unix://<validated-path> system dial-stdio`. It discards raw SSH stderr and relays concurrent HTTP, hijacked byte streams, and half-closes. A Mac or daemon outage fails that request without killing the bridge or delaying SSH readiness.

Operational boundary: this socket secures transport inside one Devbox; it does not partition the remote daemon. Every Devbox using this shared credential sees and contends for the same Mac daemon's container names and state, networks, images, volumes, build cache, CPU, and memory. Coordinate names and cleanup accordingly. Testcontainers and `docker run -p` publish on the Mac Docker host, not the Kubernetes Pod, and those ports may be reachable from LAN or tailnet peers depending on Docker Desktop, the Mac firewall, and tailnet policy. Revision `r5` adds no Kubernetes Docker TCP Service or listener; neither the local Unix socket nor separate client credentials hide cached private image layers from another client of the same daemon.

Kubernetes mounts must make all eleven Docker-host and GHCR source paths regular files at the exact names. A projected Secret's symlink front-end does not meet the non-symlink contract; mount each Secret item read-only at its final path with an explicit `subPath` file mount. Use `0400` for the Docker private key and GHCR PAT, and `0444` for the other inputs. Together with the two state mounts and two SSH-server key mounts, that is fifteen `volumeMounts`, even though the Docker-host and GHCR bundles are each one logical source. Secret updates require Pod replacement: `subPath` mounts do not receive projected updates, and the entrypoint intentionally copies validated runtime material only at container start.

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
sh -n codex-remote-devbox/ghcr-auth-command.sh
bash -n codex-remote-devbox/smoke-test.sh
node --check codex-remote-devbox/docker-bridge.js
node --check codex-remote-devbox/docker-bridge-client-smoke.js
node --check codex-remote-devbox/ghcr-auth-config.js
node --check codex-remote-devbox/ghcr-credential-helper.js
node --check codex-remote-devbox/supervisor.js
node --test \
  codex-remote-devbox/docker-bridge.test.js \
  codex-remote-devbox/ghcr-auth.test.js
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

On a native Linux host, run the full smoke command through `sudo` so its bind-mounted source fixtures are actually root-owned, matching the runtime contract. Docker Desktop for macOS presents bind-mounted fixture ownership as root inside its Linux VM, so the ordinary command above remains appropriate there. CI runs the Linux smoke as root and still uses only deterministic synthetic credentials.

The smoke test creates disposable named volumes with copy-up disabled, so fresh root-owned volume roots exercise the image bootstrap rather than inheriting the ownership of the baked directories. For an equivalent offline-target manual start, create temporary keys, a complete Docker-host bundle, and two named volumes:

```bash
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-devbox-local.XXXXXX")"
home_volume="codex-devbox-home-$$"
workspaces_volume="codex-devbox-workspaces-$$"
container_name="codex-devbox-local-$$"

mkdir -p \
  "$fixture_dir/access" \
  "$fixture_dir/host" \
  "$fixture_dir/docker-host" \
  "$fixture_dir/ghcr"
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
printf '%s' codex-smoke > "$fixture_dir/ghcr/ghcr_username"
printf '%s' github_pat_imageyard_smoke_000000000000 \
  > "$fixture_dir/ghcr/ghcr_pat"
chmod 0444 "$fixture_dir/access/authorized_keys" "$fixture_dir/docker-host"/*
chmod 0444 "$fixture_dir/ghcr/ghcr_username"
chmod 0400 \
  "$fixture_dir/client_key" \
  "$fixture_dir/host/ssh_host_ed25519_key" \
  "$fixture_dir/docker-host/ssh_client_ed25519_private_key" \
  "$fixture_dir/ghcr/ghcr_pat"

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
  --mount "type=bind,src=${fixture_dir}/ghcr,dst=/run/secrets/ghcr,readonly" \
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

Both `stat` rows must report `1000:1000 700`. The deliberately unreachable `docker.invalid` target must not delay SSH readiness. The GHCR values above are synthetic syntax fixtures, not usable credentials; never put a real PAT in shell history or a checked-in fixture. Inside the SSH session, `DOCKER_HOST` must be the local bridge URI, `TESTCONTAINERS_HOST_OVERRIDE` must equal the validated `ssh_host`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` must be `/var/run/docker.sock`, and `DOCKER_CONTEXT` must be absent. `~/.docker/config.json` must contain only the non-secret managed helper mapping plus any pre-existing unrelated state, while the runtime GHCR files remain under `/run` with the documented metadata. A Docker command is expected to fail promptly until the real Mac becomes reachable, while a later request must be able to recover without restarting the container. Remove the disposable container and volumes after the check; retaining either named volume intentionally retains its state.

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
- each missing, empty, symlinked, directory-valued, wrong-mode, or malformed GHCR source case fails generically before SSH; a valid root-owned source remains byte/metadata-identical and produces only the exact UID/GID `1000` mode-`0700` runtime directory and two mode-`0600` files;
- the helper protocol accepts only normalized `ghcr.io` lookups, returns the runtime username/PAT to Docker, rejects `store`, `erase`, unsupported hosts, malformed runtime files, oversized input, and wrong-UID execution, and never prints credential material in an error;
- a real Docker CLI request through the deterministic remote daemon uses the helper-generated registry auth successfully without `docker login`, environment credentials, or a PAT in Home, while source, runtime, Home, daemon, image/history, and captured logs remain free of unintended credential copies;
- boot-time enable preserves hostile but Docker-valid unrelated Home configuration and any legacy `auths["ghcr.io"]`; deliberate scrub removes only that exact legacy entry, disable removes only the exact managed mapping, and all three operations are idempotent. A differently managed mapping, invalid UTF-8/JSON, unsafe type, symlink, or hardlink fails without mutation; a replacement injected before the final identity check is detected and preserved. The full smoke also proves that simultaneous image-owned scrub and disable calls block on the private lock and complete serially. It does not claim preservation of an uncooperative external writer in the documented residual check-to-rename window. A real subprocess `SIGKILL` after temporary-file `fsync` leaves one image-named file that the next locked transaction validates, removes, and directory-syncs before updating;
- the bridge directory is `1000:1000` mode `0700`, the socket is `1000:1000` mode `0600`, both are non-symlink objects with monitored identity, unsafe path occupants fail closed, and verified stale sockets are removed without deleting replacements;
- both interactive and command SSH sessions receive the exact local `DOCKER_HOST`, validated-host `TESTCONTAINERS_HOST_OVERRIDE`, and `/var/run/docker.sock` override while `DOCKER_CONTEXT` is absent; direct exec remains outside this sshd contract;
- explicit system SSH configuration defeats an adversarial Home `Host docker-host` stanza, and effective `ssh -G -F /etc/ssh/ssh_config docker-host` contains the validated hostname, `HostKeyAlias docker-host`, `ConnectTimeout 10`, and other fail-closed options;
- a deterministic fake SSH/dial-stdio backend proves concurrent `/_ping`, Docker CLI and Node clients observing the same daemon identity, one fixed `/usr/bin/ssh` argv per connection, binary hijack and half-close relay, stderr isolation, prompt offline failure, and later-request recovery without the user's Mac;
- the SSH session is UID/GID `1000` and Bash is the login shell;
- `sudo -n id -u` returns `0`;
- `codex --version` reports `0.149.0` and `codex app-server --help` succeeds;
- the lean toolset and pinned Docker clients are present while daemon, Kubernetes, and infrastructure tooling is absent;
- SSH is the only TCP listener and listens only on `2222`; the bridge is AF_UNIX-only, no login banner is emitted, and no Codex app server is prestarted;
- the container starts without privileged mode, a mounted host/daemon Docker socket, or mounts beyond the documented SSH, Docker-host, GHCR, and state paths;
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
ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r5
```

## Verify publication

Inspect the remote OCI index:

```bash
docker buildx imagetools inspect \
  ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r5
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

- Never roll an `r5` Home PVC directly to `r4` while `credHelpers["ghcr.io"]="codex-ghcr"` remains: `r4` does not contain that helper. Prepare every ordinal independently while it is still running `r5`.
- Before legacy-auth scrub, quiesce every writer of `~/.docker/config.json`, run `codex-ghcr-auth disable` as `codex` on each ordinal, confirm only the exact helper mapping is absent, and verify that the untouched legacy `auths["ghcr.io"]` still provides the intended access. Then select the known-good `r4` digest. Keep the GHCR source mounted until rollback acceptance is complete; removing it early makes `r5` fail closed on restart.
- After legacy-auth scrub, there is no inline credential to resume. Keep the `r5` helper and GHCR source available until another credential path has been established and accepted on every ordinal. Either restore an operator-approved client credential without printing it, or remain on `r5`; only then quiesce external config writers, run `codex-ghcr-auth disable`, and roll to `r4`. Do not reconstruct the old inline auth from logs, backups, or shell arguments.
- If rolling between two `r5`-compatible releases, the exact helper mapping and runtime Secret contract may remain, but still verify the target image contains `docker-credential-codex-ghcr` before replacement.
- For a general image rollback, select an older known-good immutable tag or, preferably, its recorded digest after completing any version-specific state migration above.
- Never delete or overwrite the defective tag as part of normal remediation.
- When Codex remains `0.149.0`, fix a defect in `r5` with a new `codex-0.149.0-r6`; continue incrementing the revision for later packaging fixes.
- If a workflow cannot prove whether the target tag exists, stop. Resolve registry authentication or availability and rerun the complete publish workflow.
- If publication partially succeeds, inspect the registry before retrying. Any existing target tag requires a new revision.
