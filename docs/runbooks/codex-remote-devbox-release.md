# Codex Remote Devbox Release Runbook

This runbook covers building, validating, publishing, verifying, and rolling back the public Codex remote devbox image. It does not define a deployment platform or network topology.

## Current release contract

- Image: `ghcr.io/ytbits/codex-remote-devbox`
- Tag: `codex-0.149.0-r2`
- Build context: `codex-remote-devbox/`
- Dockerfile: `codex-remote-devbox/Dockerfile`
- Platforms: `linux/amd64`, `linux/arm64`
- Base: `node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03`
- Codex package: `@openai/codex@0.149.0`

Tags use `codex-<CODEX_VERSION>-r<REVISION>`. A Codex upgrade starts at `r1`; a packaging-only change for the same Codex version increments the revision. Never reuse or overwrite a published tag, and never publish a moving alias.

`codex-0.149.0-r1` remains the historical initial release. Revision `r2` adds the mandatory state-mount bootstrap contract without changing the Codex version.

The runtime authorized-keys file accepts bare OpenSSH public-key lines only. Do not add per-key options or place a private key, known-hosts file, or another key format at that path.

## Runtime mount contract

Every start must provide four explicit mounts:

- a state mount at `/home/codex`;
- a state mount at `/workspaces`;
- the authorized-keys file at `/run/secrets/ssh-access/authorized_keys`, read-only;
- the Ed25519 host private key at `/run/secrets/ssh-host/ssh_host_ed25519_key`, read-only.

The two state paths must each be real, non-symlink directories and exact mountpoints. Mounting only `/home`, `/`, or another parent does not qualify. After validating identity, mount types, SSH inputs, and OpenSSH configuration, the entrypoint normalizes only each state-mount root to UID/GID `1000` and mode `0700`. It never recursively changes, seeds, wipes, or migrates descendants. It then creates and removes a randomized probe as `codex`; a missing, invalid, read-only, or otherwise unusable mount fails closed before sshd starts.

Validated SSH inputs are copied to root-owned runtime files. The entrypoint must not alter source bytes or metadata, log key material, or copy key material into either state mount. The runtime process chain is root `tini -g` to the root entrypoint to `exec` foreground sshd so termination signals reach sshd and its active sessions.

## Prepare a release

1. Start a `codex/` feature branch from current `main`.
2. Select the current non-prerelease Codex npm release and pin the exact version in the Dockerfile and workflow release constants.
3. Confirm that the package supports both target architectures.
4. Pin the exact Node image version and manifest-list digest. Record both in the Dockerfile, image contract, and release documentation.
5. Choose the tag revision according to the rule above and update every release reference together.
6. Update `README.md`, `AGENTS.md`, `docs/changelog.md`, this runbook, and the ADR if the durable contract changed.

Do not put credentials, local configuration, SSH keys, private hosts, or deployment-specific examples in the build context, documentation, labels, build arguments, or workflow logs.

## Run local validation

Run the repository checks from the repository root:

```bash
sh -n codex-remote-devbox/entrypoint.sh
bash -n codex-remote-devbox/smoke-test.sh
git diff --check
```

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

The smoke test creates disposable named volumes with copy-up disabled, so fresh root-owned volume roots exercise the image bootstrap rather than inheriting the ownership of the baked directories. For an equivalent manual start, create temporary keys and two named volumes:

```bash
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-devbox-local.XXXXXX")"
home_volume="codex-devbox-home-$$"
workspaces_volume="codex-devbox-workspaces-$$"
container_name="codex-devbox-local-$$"

mkdir -p "$fixture_dir/access" "$fixture_dir/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/client_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host/ssh_host_ed25519_key"
cp "$fixture_dir/client_key.pub" "$fixture_dir/access/authorized_keys"
chmod 0400 "$fixture_dir/client_key" "$fixture_dir/host/ssh_host_ed25519_key"
chmod 0444 "$fixture_dir/access/authorized_keys"

docker volume create "$home_volume"
docker volume create "$workspaces_volume"
docker run --detach \
  --name "$container_name" \
  --publish 127.0.0.1:2222:2222 \
  --mount "type=volume,src=${home_volume},dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=${workspaces_volume},dst=/workspaces,volume-nocopy" \
  --mount "type=bind,src=${fixture_dir}/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
  --mount "type=bind,src=${fixture_dir}/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
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

Both `stat` rows must report `1000:1000 700`. Remove the disposable container and volumes after the check; retaining either named volume intentionally retains its state.

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
- the SSH session is UID/GID `1000` and Bash is the login shell;
- `sudo -n id -u` returns `0`;
- `codex --version` reports `0.149.0` and `codex app-server --help` succeeds;
- the lean toolset is present while Docker and infrastructure CLIs are absent;
- SSH listens only on `2222`, emits no login banner, and no Codex app server is prestarted;
- the container starts without privileged mode, a Docker socket, or mounts beyond the documented key and state paths;
- the image and its history contain no test key or token marker;
- reusing the same externally supplied host key preserves the SSH fingerprint;
- mounted home and workspace directories preserve state across container replacement;
- `SIGTERM` reaches the `tini -g`/entrypoint/sshd process group, stops active sessions within the bounded timeout, and does not require `SIGKILL`.

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
ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r2
```

## Verify publication

Inspect the remote OCI index:

```bash
docker buildx imagetools inspect \
  ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r2
```

Record in the release or pull-request evidence:

- the source Git revision;
- the OCI index digest;
- the `linux/amd64` manifest digest;
- the `linux/arm64` manifest digest;
- confirmation that no moving tags were published.

Pull and smoke-test the published image on each available native platform. Confirm its OCI labels identify the source repository, source revision, base image, and exact Codex version.

## Rollback and failed releases

- Roll back a consumer by selecting an older known-good immutable tag or, preferably, its recorded digest.
- Never delete or overwrite the defective tag as part of normal remediation.
- When Codex remains `0.149.0`, fix a defect in `r2` and release `codex-0.149.0-r3`; continue incrementing the revision for later packaging fixes.
- If a workflow cannot prove whether the target tag exists, stop. Resolve registry authentication or availability and rerun the complete publish workflow.
- If publication partially succeeds, inspect the registry before retrying. Any existing target tag requires a new revision.
