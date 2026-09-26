#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image="${1:-ghcr.io/ytbits/codex-remote-devbox:codex-0.157.1-r1}"
expected_codex_version="${EXPECTED_CODEX_VERSION:-0.157.1}"
expected_docker_ce_cli_version="${EXPECTED_DOCKER_CLI_PACKAGE_VERSION:-5:29.7.2-1~debian.12~bookworm}"
expected_docker_buildx_version="${EXPECTED_DOCKER_BUILDX_PACKAGE_VERSION:-0.36.1-1~debian.12~bookworm}"
expected_docker_compose_version="${EXPECTED_DOCKER_COMPOSE_PACKAGE_VERSION:-5.5.0-1~debian.12~bookworm}"
expected_docker_cli_semver="${EXPECTED_DOCKER_CLI_SEMVER:-29.7.2}"
expected_docker_buildx_semver="${EXPECTED_DOCKER_BUILDX_SEMVER:-0.36.1}"
expected_docker_compose_semver="${EXPECTED_DOCKER_COMPOSE_SEMVER:-5.5.0}"
secret_marker="IMAGEYARD_SMOKE_SECRET_DO_NOT_BAKE_7e4fdd65"
docker_secret_marker="IMAGEYARD_DOCKER_HOST_SECRET_DO_NOT_PERSIST_903ea3d1"
ghcr_pat_marker="ghp_IMAGEYARD_GHCR_RUNTIME_ONLY_SECRET_51f3d92a"
legacy_ghcr_auth_marker="IMAGEYARD_LEGACY_GHCR_AUTH_PRESERVE_THEN_SCRUB_67b2c8a0"
ghcr_username="imageyard-smoke"
state_marker="IMAGEYARD_SMOKE_STATE_PERSISTS_b91c6c82"
docker_host_alias="docker-host"
docker_host_hostname="imageyard-fake-docker-host"
docker_host_port="2222"
docker_host_user="codex"
docker_host_uri="ssh://docker-host/Users/imageyard/.docker/run/docker.sock"
docker_remote_socket_path="/Users/imageyard/.docker/run/docker.sock"
docker_bridge_runtime_dir="/run/codex-remote-devbox/docker-bridge"
docker_bridge_socket="$docker_bridge_runtime_dir/docker.sock"
docker_bridge_uri="unix://$docker_bridge_socket"
ghcr_runtime_dir="/run/codex-remote-devbox/ghcr"
ghcr_pull_image="ghcr.io/ytbits/imageyard-private-smoke:fixture"
testcontainers_docker_socket_override="/var/run/docker.sock"
fake_docker_daemon_id="IMAGEYARD-R5-FAKE-DAEMON-ID"
offline_docker_host_hostname="127.0.0.1"
offline_docker_host_port="1"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-devbox-smoke.XXXXXX")"
fixture_token="${fixture_dir##*.}"
name_prefix="codex-remote-devbox-smoke-$$-${fixture_token}"

primary_container="${name_prefix}-primary"
restart_container="${name_prefix}-restart"
offline_container="${name_prefix}-offline"
bridge_failure_container="${name_prefix}-bridge-failure"
sshd_failure_container="${name_prefix}-sshd-failure"
docker_backend_container="${name_prefix}-docker-backend"
docker_backend_network="${name_prefix}-backend-network"
audit_container="${name_prefix}-audit"
filesystem_audit_container="${name_prefix}-filesystem-audit"
volume_helper_container="${name_prefix}-volume-helper"
fixture_cleanup_container="${name_prefix}-fixture-cleanup"
missing_access_container="${name_prefix}-missing-access"
missing_host_container="${name_prefix}-missing-host"
empty_access_container="${name_prefix}-empty-access"
invalid_access_container="${name_prefix}-invalid-access"
mixed_invalid_access_container="${name_prefix}-mixed-invalid-access"
private_access_container="${name_prefix}-private-access"
invalid_host_container="${name_prefix}-invalid-host"
missing_home_container="${name_prefix}-missing-home"
missing_workspace_container="${name_prefix}-missing-workspace"
missing_path_home_container="${name_prefix}-missing-path-home"
parent_home_container="${name_prefix}-parent-home"
file_home_container="${name_prefix}-file-home"
file_workspace_container="${name_prefix}-file-workspace"
symlink_home_container="${name_prefix}-symlink-home"
symlink_workspace_container="${name_prefix}-symlink-workspace"
readonly_home_container="${name_prefix}-readonly-home"
readonly_workspace_container="${name_prefix}-readonly-workspace"
malformed_docker_config_container="${name_prefix}-malformed-docker-config"
symlink_docker_config_container="${name_prefix}-symlink-docker-config"

home_volume="${name_prefix}-home"
workspace_volume="${name_prefix}-workspaces"
offline_home_volume="${name_prefix}-offline-home"
offline_workspace_volume="${name_prefix}-offline-workspaces"
supervision_home_volume="${name_prefix}-supervision-home"
supervision_workspace_volume="${name_prefix}-supervision-workspaces"
support_home_volume="${name_prefix}-support-home"
support_workspace_volume="${name_prefix}-support-workspaces"
readonly_home_volume="${name_prefix}-readonly-home"
readonly_workspace_volume="${name_prefix}-readonly-workspaces"
invalid_secret_home_volume="${name_prefix}-invalid-secret-home"
invalid_secret_workspace_volume="${name_prefix}-invalid-secret-workspaces"
parent_home_volume="${name_prefix}-parent-home"
malformed_config_home_volume="${name_prefix}-malformed-config-home"
malformed_config_workspace_volume="${name_prefix}-malformed-config-workspaces"
symlink_config_home_volume="${name_prefix}-symlink-config-home"
symlink_config_workspace_volume="${name_prefix}-symlink-config-workspaces"

declare -a cleanup_containers=(
  "$primary_container"
  "$restart_container"
  "$offline_container"
  "$bridge_failure_container"
  "$sshd_failure_container"
  "$docker_backend_container"
  "$audit_container"
  "$filesystem_audit_container"
  "$volume_helper_container"
  "$fixture_cleanup_container"
  "$missing_access_container"
  "$missing_host_container"
  "$empty_access_container"
  "$invalid_access_container"
  "$mixed_invalid_access_container"
  "$private_access_container"
  "$invalid_host_container"
  "$missing_home_container"
  "$missing_workspace_container"
  "$missing_path_home_container"
  "$parent_home_container"
  "$file_home_container"
  "$file_workspace_container"
  "$symlink_home_container"
  "$symlink_workspace_container"
  "$readonly_home_container"
  "$readonly_workspace_container"
  "$malformed_docker_config_container"
  "$symlink_docker_config_container"
)
declare -a cleanup_volumes=()
declare -a secret_source_files=()
declare -a docker_host_source_files=()
declare -a sensitive_docker_host_files=()
declare -a ghcr_source_files=()
forward_pid=""
signal_session_pid=""
bridge_hold_pid=""
signal_bridge_pid=""

fail() {
  printf 'smoke-test: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local original_status=$?

  trap - EXIT INT TERM
  set +e

  if [ -n "$forward_pid" ]; then
    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$signal_session_pid" ]; then
    kill "$signal_session_pid" >/dev/null 2>&1 || true
    wait "$signal_session_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$bridge_hold_pid" ]; then
    kill "$bridge_hold_pid" >/dev/null 2>&1 || true
    wait "$bridge_hold_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$signal_bridge_pid" ]; then
    kill "$signal_bridge_pid" >/dev/null 2>&1 || true
    wait "$signal_bridge_pid" >/dev/null 2>&1 || true
  fi

  docker rm -f "${cleanup_containers[@]}" >/dev/null 2>&1 || true
  docker network rm "$docker_backend_network" >/dev/null 2>&1 || true
  if [ "${#cleanup_volumes[@]}" -gt 0 ]; then
    docker volume rm -f "${cleanup_volumes[@]}" >/dev/null 2>&1 || true
  fi

  # SSH sessions can create UID 1000-owned files in the mktemp fixture. Use
  # container root to remove only that exact directory without crossing a
  # filesystem boundary, then let the unprivileged runner remove its root.
  if [ -d "$fixture_dir" ] \
    && docker image inspect "$image" >/dev/null 2>&1; then
    docker run --rm \
      --name "$fixture_cleanup_container" \
      --network none \
      --user 0:0 \
      --entrypoint /bin/sh \
      --mount "type=bind,src=$fixture_dir,dst=/cleanup" \
      "$image" \
      -c 'find /cleanup -xdev -depth -mindepth 1 -delete' \
      >/dev/null 2>&1 || true
  fi
  rmdir -- "$fixture_dir" >/dev/null 2>&1 || true
  if [ -e "$fixture_dir" ]; then
    printf 'smoke-test: warning: could not remove fixture directory: %s\n' \
      "$fixture_dir" >&2
  fi

  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$state_marker" != "$secret_marker" ] \
  || fail "state and secret markers must be distinct"
[ "$state_marker" != "$docker_secret_marker" ] \
  || fail "state and Docker host secret markers must be distinct"
[ "$secret_marker" != "$docker_secret_marker" ] \
  || fail "SSH and Docker host secret markers must be distinct"
[ "$ghcr_pat_marker" != "$secret_marker" ] \
  || fail "SSH and GHCR secret markers must be distinct"
[ "$ghcr_pat_marker" != "$docker_secret_marker" ] \
  || fail "Docker host and GHCR secret markers must be distinct"
[ "$ghcr_pat_marker" != "$legacy_ghcr_auth_marker" ] \
  || fail "runtime and legacy GHCR markers must be distinct"

for command_name in base64 cksum cmp docker ssh ssh-keygen ssh-keyscan stat; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required host command is unavailable: $command_name"
done

legacy_ghcr_auth_encoded="$(
  printf '%s' "ytbits:$legacy_ghcr_auth_marker" | base64 | tr -d '\n'
)"
[ -n "$legacy_ghcr_auth_encoded" ] \
  || fail "could not create the legacy GHCR auth fixture"

docker image inspect "$image" >/dev/null 2>&1 \
  || fail "image is not available locally: $image"
for fixture_file in \
  "$script_dir/app-server-smoke.js" \
  "$script_dir/docker-bridge-client-smoke.js" \
  "$script_dir/fake-docker-backend.py" \
  "$script_dir/fake-docker-sshd_config"; do
  [ -f "$fixture_file" ] || fail "required smoke fixture is unavailable: $fixture_file"
done

mkdir -p \
  "$fixture_dir/access" \
  "$fixture_dir/host" \
  "$fixture_dir/docker-host" \
  "$fixture_dir/ghcr" \
  "$fixture_dir/docker-backend"

ssh-keygen -q -t ed25519 -N '' -C "$secret_marker" -f "$fixture_dir/client_key"
ssh-keygen -q -t ed25519 -N '' -C unknown-smoke-client -f "$fixture_dir/unknown_key"
ssh-keygen -q -t ed25519 -N '' -C devbox-smoke-host -f "$fixture_dir/host/ssh_host_ed25519_key"
cp "$fixture_dir/client_key.pub" "$fixture_dir/access/authorized_keys"
chmod 0400 "$fixture_dir/client_key" "$fixture_dir/unknown_key" "$fixture_dir/host/ssh_host_ed25519_key"
chmod 0444 "$fixture_dir/access/authorized_keys"
: > "$fixture_dir/empty_authorized_keys"
printf '%s\n' 'not-an-authorized-key' > "$fixture_dir/invalid_authorized_keys"
cp "$fixture_dir/client_key.pub" "$fixture_dir/mixed_invalid_authorized_keys"
printf 'ssh-ed25519 AAAA %s\n' "$secret_marker" \
  >> "$fixture_dir/mixed_invalid_authorized_keys"
printf '%s\n' 'not-a-private-key' > "$fixture_dir/invalid_host_key"

ssh-keygen -q -t ed25519 -N '' -C "$docker_secret_marker" \
  -f "$fixture_dir/docker_client_key"
ssh-keygen -q -t ed25519 -N '' -C docker-host-smoke-server \
  -f "$fixture_dir/docker_remote_host_key"
ssh-keygen -q -t ed25519 -N '' -C alternate-docker-client \
  -f "$fixture_dir/alternate_docker_client_key"
ssh-keygen -q -t ed25519 -N '' -C alternate-docker-host \
  -f "$fixture_dir/alternate_docker_remote_host_key"
ssh-keygen -q -t rsa -b 2048 -N '' -C wrong-client-key-type \
  -f "$fixture_dir/rsa_docker_client_key"
ssh-keygen -q -t rsa -b 2048 -N '' -C wrong-host-key-type \
  -f "$fixture_dir/rsa_docker_remote_host_key"

docker_client_fingerprint="$(
  ssh-keygen -E sha256 -lf "$fixture_dir/docker_client_key.pub" \
    | awk 'NR == 1 { print $2 }'
)"
docker_remote_host_fingerprint="$(
  ssh-keygen -E sha256 -lf "$fixture_dir/docker_remote_host_key.pub" \
    | awk 'NR == 1 { print $2 }'
)"
alternate_docker_client_fingerprint="$(
  ssh-keygen -E sha256 -lf "$fixture_dir/alternate_docker_client_key.pub" \
    | awk 'NR == 1 { print $2 }'
)"
alternate_docker_remote_host_fingerprint="$(
  ssh-keygen -E sha256 -lf "$fixture_dir/alternate_docker_remote_host_key.pub" \
    | awk 'NR == 1 { print $2 }'
)"
[ -n "$docker_client_fingerprint" ] \
  || fail "could not derive the Docker host client fingerprint fixture"
[ -n "$docker_remote_host_fingerprint" ] \
  || fail "could not derive the Docker host fingerprint fixture"

docker_client_public_key_material="$(
  awk 'NR == 1 { print $1 " " $2 }' "$fixture_dir/docker_client_key.pub"
)"
docker_remote_host_public_key_material="$(
  awk 'NR == 1 { print $1 " " $2 }' "$fixture_dir/docker_remote_host_key.pub"
)"
alternate_docker_remote_host_key_blob="$(
  awk 'NR == 1 { print $2 }' "$fixture_dir/alternate_docker_remote_host_key.pub"
)"
rsa_docker_remote_host_key_blob="$(
  awk 'NR == 1 { print $2 }' "$fixture_dir/rsa_docker_remote_host_key.pub"
)"
[ -n "$docker_client_public_key_material" ] \
  || fail "could not derive the Docker host client public key fixture"
[ -n "$docker_remote_host_public_key_material" ] \
  || fail "could not derive the Docker host public key fixture"

cp "$fixture_dir/docker_client_key" \
  "$fixture_dir/docker-host/ssh_client_ed25519_private_key"
printf '%s\n' "$docker_host_uri" \
  > "$fixture_dir/docker-host/docker_host"
printf '%s\n' "$docker_host_alias" \
  > "$fixture_dir/docker-host/ssh_alias"
printf '%s\n' "$docker_host_hostname" \
  > "$fixture_dir/docker-host/ssh_host"
printf '%s\n' "$docker_host_port" \
  > "$fixture_dir/docker-host/ssh_port"
printf '%s\n' "$docker_host_user" \
  > "$fixture_dir/docker-host/ssh_user"
printf '%s\n' "$docker_client_fingerprint" \
  > "$fixture_dir/docker-host/ssh_client_ed25519_fingerprint"
printf '%s\n' "$docker_remote_host_fingerprint" \
  > "$fixture_dir/docker-host/ssh_host_ed25519_fingerprint"
printf '%s %s\n' \
  "$docker_host_alias" \
  "$docker_remote_host_public_key_material" \
  > "$fixture_dir/docker-host/ssh_known_hosts"
chmod 0400 "$fixture_dir/docker-host/ssh_client_ed25519_private_key"
chmod 0444 \
  "$fixture_dir/docker-host/docker_host" \
  "$fixture_dir/docker-host/ssh_alias" \
  "$fixture_dir/docker-host/ssh_host" \
  "$fixture_dir/docker-host/ssh_port" \
  "$fixture_dir/docker-host/ssh_user" \
  "$fixture_dir/docker-host/ssh_client_ed25519_fingerprint" \
  "$fixture_dir/docker-host/ssh_host_ed25519_fingerprint" \
  "$fixture_dir/docker-host/ssh_known_hosts"

printf '%s' "$ghcr_username" > "$fixture_dir/ghcr/ghcr_username"
printf '%s' "$ghcr_pat_marker" > "$fixture_dir/ghcr/ghcr_pat"
chmod 0444 "$fixture_dir/ghcr/ghcr_username"
chmod 0400 "$fixture_dir/ghcr/ghcr_pat"
printf '%s\n' \
  "{\"username\":\"$ghcr_username\",\"secret\":\"$ghcr_pat_marker\"}" \
  > "$fixture_dir/docker-backend/expected-ghcr-auth.json"
chmod 0444 "$fixture_dir/docker-backend/expected-ghcr-auth.json"

cp "$fixture_dir/docker_remote_host_key" \
  "$fixture_dir/docker-backend/ssh_host_ed25519_key"
cp "$fixture_dir/docker_client_key.pub" \
  "$fixture_dir/docker-backend/authorized_keys"
cp "$script_dir/fake-docker-sshd_config" \
  "$fixture_dir/docker-backend/sshd_config"
chmod 0400 "$fixture_dir/docker-backend/ssh_host_ed25519_key"
chmod 0444 \
  "$fixture_dir/docker-backend/authorized_keys" \
  "$fixture_dir/docker-backend/sshd_config"

secret_source_files=(
  "$fixture_dir/access/authorized_keys"
  "$fixture_dir/host/ssh_host_ed25519_key"
  "$fixture_dir/empty_authorized_keys"
  "$fixture_dir/invalid_authorized_keys"
  "$fixture_dir/mixed_invalid_authorized_keys"
  "$fixture_dir/client_key"
  "$fixture_dir/invalid_host_key"
  "$fixture_dir/docker-backend/authorized_keys"
  "$fixture_dir/docker-backend/ssh_host_ed25519_key"
  "$fixture_dir/docker-backend/expected-ghcr-auth.json"
)
docker_host_source_files=(
  "$fixture_dir/docker-host/docker_host"
  "$fixture_dir/docker-host/ssh_alias"
  "$fixture_dir/docker-host/ssh_host"
  "$fixture_dir/docker-host/ssh_port"
  "$fixture_dir/docker-host/ssh_user"
  "$fixture_dir/docker-host/ssh_client_ed25519_private_key"
  "$fixture_dir/docker-host/ssh_client_ed25519_fingerprint"
  "$fixture_dir/docker-host/ssh_host_ed25519_fingerprint"
  "$fixture_dir/docker-host/ssh_known_hosts"
)
sensitive_docker_host_files=(
  "$fixture_dir/docker-host/docker_host"
  "$fixture_dir/docker-host/ssh_client_ed25519_private_key"
  "$fixture_dir/docker-host/ssh_client_ed25519_fingerprint"
  "$fixture_dir/docker-host/ssh_host_ed25519_fingerprint"
  "$fixture_dir/docker-host/ssh_known_hosts"
)
ghcr_source_files=(
  "$fixture_dir/ghcr/ghcr_username"
  "$fixture_dir/ghcr/ghcr_pat"
)
authorized_key_material="$(awk 'NR == 1 { print $1 " " $2 }' "$fixture_dir/access/authorized_keys")"
host_public_key_material="$(ssh-keygen -y -f "$fixture_dir/host/ssh_host_ed25519_key")"
[ -n "$authorized_key_material" ] || fail "could not derive the authorized public key fixture"
[ -n "$host_public_key_material" ] || fail "could not derive the host public key fixture"

record_secret_sources() {
  local source_file
  local source_metadata

  for source_file in \
    "${secret_source_files[@]}" \
    "${docker_host_source_files[@]}" \
    "${ghcr_source_files[@]}"; do
    cksum "$source_file"
    if source_metadata="$(stat -f '%u:%g:%Lp:%m' "$source_file" 2>/dev/null)"; then
      :
    else
      source_metadata="$(stat -c '%u:%g:%a:%Y' "$source_file")"
    fi
    printf '%s  %s\n' "$source_metadata" "$source_file"
  done
}

record_secret_sources > "$fixture_dir/secret-sources.before"

state_volume_run() {
  local volume_name="$1"
  local script="$2"
  shift 2

  docker run --rm \
    --name "$volume_helper_container" \
    --network none \
    --user 0:0 \
    --entrypoint /bin/sh \
    --mount "type=volume,src=$volume_name,dst=/state,volume-nocopy" \
    "$image" \
    -c "$script" smoke-volume "$@"
}

create_state_volume() {
  local volume_name="$1"

  if docker volume inspect "$volume_name" >/dev/null 2>&1; then
    fail "refusing to reuse a pre-existing smoke-test volume: $volume_name"
  fi
  docker volume create "$volume_name" >/dev/null
  cleanup_volumes+=("$volume_name")
  if ! state_volume_run "$volume_name" '
    set -eu
    first_entry="$(find /state -xdev -mindepth 1 -print -quit)"
    test -z "$first_entry"
    chown 0:0 -- /state
    chmod 0755 -- /state
    test "$(stat -c "%u:%g:%a" -- /state)" = 0:0:755
  '; then
    fail "fresh volume $volume_name is not empty root:root mode 0755"
  fi
}

set_volume_root_metadata() {
  local volume_name="$1"
  local owner="$2"
  local mode="$3"

  if ! state_volume_run "$volume_name" '
    set -eu
    chown "$1" -- /state
    chmod "$2" -- /state
  ' "$owner" "$mode"; then
    fail "could not set root metadata for state volume $volume_name"
  fi
}

seed_state_volume() {
  local volume_name="$1"
  local label="$2"
  local directory_owner="$3"
  local file_owner="$4"
  local content="$5"

  if ! state_volume_run "$volume_name" '
    set -eu
    label=$1
    directory_owner=$2
    file_owner=$3
    content=$4
    seed_root="/state/seed-${label}"
    mkdir -p "$seed_root/nested"
    printf "%s\n" "$content" > "$seed_root/nested/content.txt"
    printf "%s-hidden\n" "$content" > "$seed_root/nested/.hidden"
    ln "$seed_root/nested/content.txt" "$seed_root/nested/content.hardlink"
    ln -s nested/content.txt "$seed_root/content.symlink"
    chown "$directory_owner" "$seed_root" "$seed_root/nested"
    chmod 0751 "$seed_root" "$seed_root/nested"
    chown "$file_owner" "$seed_root/nested/content.txt" "$seed_root/nested/.hidden"
    chown -h "$file_owner" "$seed_root/content.symlink"
    chmod 0640 "$seed_root/nested/content.txt"
    chmod 0600 "$seed_root/nested/.hidden"
    touch -d @1700000000 "$seed_root/nested/content.txt" "$seed_root/nested/.hidden"
    touch -h -d @1700000000 "$seed_root/content.symlink"
    touch -d @1700000000 "$seed_root/nested" "$seed_root"
  ' "$label" "$directory_owner" "$file_owner" "$content"; then
    fail "could not seed state volume $volume_name"
  fi
}

seed_legacy_home_ssh_config() {
  local volume_name="$1"

  if ! state_volume_run "$volume_name" '
    set -eu
    install -d -o 1000 -g 1000 -m 0700 /state/.ssh
    printf "%s\n" \
      "Host docker-mac" \
      "  HostName legacy-home.invalid" \
      "  User legacy-user" \
      "  IdentityFile ~/.ssh/legacy-docker-mac" \
      "" \
      "Host docker-host" \
      "  HostName adversarial-home.invalid" \
      "  User adversarial-user" \
      "  Port 1" \
      "  ProxyCommand false" \
      > /state/.ssh/config
    chown 1000:1000 /state/.ssh/config
    chmod 0600 /state/.ssh/config
    touch -d @1700000000 /state/.ssh/config /state/.ssh
  '; then
    fail "could not seed the legacy Home SSH configuration"
  fi
}

assert_legacy_home_ssh_config_preserved() {
  local volume_name="$1"

  if ! state_volume_run "$volume_name" '
    set -eu
    test "$(stat -c "%u:%g:%a:%Y" -- /state/.ssh)" = 1000:1000:700:1700000000
    test "$(stat -c "%u:%g:%a:%Y" -- /state/.ssh/config)" = 1000:1000:600:1700000000
    expected="$(printf "%s\n" \
      "Host docker-mac" \
      "  HostName legacy-home.invalid" \
      "  User legacy-user" \
      "  IdentityFile ~/.ssh/legacy-docker-mac" \
      "" \
      "Host docker-host" \
      "  HostName adversarial-home.invalid" \
      "  User adversarial-user" \
      "  Port 1" \
      "  ProxyCommand false")"
    test "$(cat /state/.ssh/config)" = "$expected"
    test ! -e /state/.ssh/ssh_client_ed25519_private_key
    test ! -e /state/.ssh/ssh_known_hosts
  '; then
    fail "legacy Home SSH configuration changed"
  fi
}

seed_legacy_home_docker_config() {
  local volume_name="$1"

  if ! state_volume_run "$volume_name" '
    set -eu
    install -d -o 1000 -g 1000 -m 0755 /state/.docker
    printf "%s\n" \
      "{\"auths\":{\"ghcr.io\":{\"auth\":\"$1\"},\"registry.example.test\":{\"auth\":\"dW5yZWxhdGVkOnByZXNlcnZlZA==\"}},\"credHelpers\":{\"registry.example.test\":\"pass\"},\"currentContext\":\"preserved-context\",\"plugins\":{\"buildx\":{\"enabled\":\"true\"}}}" \
      > /state/.docker/config.json
    chown 1000:1000 /state/.docker/config.json
    chmod 0644 /state/.docker/config.json
  ' "$legacy_ghcr_auth_encoded"; then
    fail "could not seed the legacy Home Docker configuration"
  fi
}

assert_home_docker_config_enabled() {
  local volume_name="$1"
  local expected_legacy_state="$2"

  if ! state_volume_run "$volume_name" '
    set -eu
    expected_legacy_state=$1
    legacy_auth=$2
    runtime_pat=$3
    config=/state/.docker/config.json
    test ! -L /state/.docker
    test ! -L "$config"
    test "$(stat -c "%u:%g:%a" -- /state/.docker)" = 1000:1000:700
    test "$(stat -c "%u:%g:%a" -- "$config")" = 1000:1000:600
    jq -e \
      --arg legacy "$legacy_auth" \
      --arg expected "$expected_legacy_state" \
      '\''
        .credHelpers["ghcr.io"] == "codex-ghcr" and
        .credHelpers["registry.example.test"] == "pass" and
        .auths["registry.example.test"].auth == "dW5yZWxhdGVkOnByZXNlcnZlZA==" and
        .currentContext == "preserved-context" and
        .plugins.buildx.enabled == "true" and
        (if $expected == "present" then .auths["ghcr.io"].auth == $legacy else (.auths | has("ghcr.io") | not) end)
      '\'' "$config" >/dev/null
    if grep -Fq -- "$runtime_pat" "$config"; then
      exit 1
    fi
  ' "$expected_legacy_state" "$legacy_ghcr_auth_encoded" "$ghcr_pat_marker"; then
    fail "Home Docker configuration does not preserve the managed GHCR contract"
  fi
}

record_home_docker_config_metadata() {
  local volume_name="$1"

  state_volume_run "$volume_name" '
    set -eu
    stat -c "%i:%s:%Y:%a:%u:%g" -- /state/.docker/config.json
    sha256sum /state/.docker/config.json
  '
}

assert_seed_preserved() {
  local volume_name="$1"
  local label="$2"
  local directory_owner="$3"
  local file_owner="$4"
  local content="$5"

  if ! state_volume_run "$volume_name" '
    set -eu
    label=$1
    directory_owner=$2
    file_owner=$3
    content=$4
    seed_root="/state/seed-${label}"
    test "$(stat -c "%u:%g:%a" -- "$seed_root")" = "${directory_owner}:751"
    test "$(stat -c "%u:%g:%a" -- "$seed_root/nested")" = "${directory_owner}:751"
    test "$(stat -c "%u:%g:%a" -- "$seed_root/nested/content.txt")" = "${file_owner}:640"
    test "$(stat -c "%u:%g:%a" -- "$seed_root/nested/.hidden")" = "${file_owner}:600"
    test "$(stat -c "%u:%g" -- "$seed_root/content.symlink")" = "$file_owner"
    test "$(cat "$seed_root/nested/content.txt")" = "$content"
    test "$(cat "$seed_root/nested/.hidden")" = "${content}-hidden"
    test "$(cat "$seed_root/nested/content.hardlink")" = "$content"
    test "$(readlink "$seed_root/content.symlink")" = nested/content.txt
    test "$(stat -c "%i" -- "$seed_root/nested/content.txt")" = "$(stat -c "%i" -- "$seed_root/nested/content.hardlink")"
    test "$(stat -c "%h" -- "$seed_root/nested/content.txt")" = 2
    for preserved_path in \
      "$seed_root" \
      "$seed_root/nested" \
      "$seed_root/nested/content.txt" \
      "$seed_root/nested/.hidden" \
      "$seed_root/content.symlink"; do
      test "$(stat -c "%Y" -- "$preserved_path")" = 1700000000
    done
  ' "$label" "$directory_owner" "$file_owner" "$content"; then
    fail "nested content or metadata changed in state volume $volume_name"
  fi
}

assert_volume_root_metadata() {
  local volume_name="$1"
  local expected_metadata="$2"

  if ! state_volume_run "$volume_name" '
    set -eu
    test "$(stat -c "%u:%g:%a" -- /state)" = "$1"
  ' "$expected_metadata"; then
    fail "state volume $volume_name root metadata is not $expected_metadata"
  fi
}

assert_no_probe_leftovers() {
  local volume_name="$1"

  if ! state_volume_run "$volume_name" '
    set -eu
    first_probe="$(find /state -xdev -name ".codex-remote-devbox-write-test.*" -print -quit)"
    test -z "$first_probe"
  '; then
    fail "state volume $volume_name contains an entrypoint write-probe leftover"
  fi
}

assert_volume_top_level_entries() {
  local volume_name="$1"
  shift
  local actual_entries
  local expected_entries

  expected_entries="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  if ! actual_entries="$(state_volume_run "$volume_name" '
    set -eu
    listing=/tmp/state-top-level-entries
    trap '\''rm -f -- "$listing"'\'' EXIT HUP INT TERM
    find /state -xdev -mindepth 1 -maxdepth 1 -printf "%f\n" > "$listing"
    LC_ALL=C sort -o "$listing" "$listing"
    cat "$listing"
  ')"; then
    fail "could not inspect top-level entries in state volume $volume_name"
  fi
  [ "$actual_entries" = "$expected_entries" ] \
    || fail "state volume $volume_name contains unexpected top-level entries (expected: ${expected_entries//$'\n'/, }; found: ${actual_entries//$'\n'/, })"
}

assert_state_excludes_secret_marker() {
  local volume_name="$1"

  if ! state_volume_run "$volume_name" '
    set -eu
    for forbidden_material in "$@" "-----BEGIN OPENSSH PRIVATE KEY-----"; do
      grep_status=0
      grep -r -F -q -- "$forbidden_material" /state 2>/dev/null || grep_status=$?
      case "$grep_status" in
        0) exit 1 ;;
        1) ;;
        *) exit 2 ;;
      esac
    done
  ' \
    "$secret_marker" \
    "$docker_secret_marker" \
    "$authorized_key_material" \
    "$host_public_key_material" \
    "$docker_client_public_key_material" \
    "$docker_remote_host_public_key_material" \
    "$docker_client_fingerprint" \
    "$docker_remote_host_fingerprint" \
    "$docker_host_uri" \
    "$ghcr_pat_marker"; then
    fail "state volume $volume_name contains runtime SSH, Docker host, or GHCR material"
  fi
}

for volume_name in \
  "$home_volume" \
  "$workspace_volume" \
  "$offline_home_volume" \
  "$offline_workspace_volume" \
  "$supervision_home_volume" \
  "$supervision_workspace_volume" \
  "$support_home_volume" \
  "$support_workspace_volume" \
  "$readonly_home_volume" \
  "$readonly_workspace_volume" \
  "$invalid_secret_home_volume" \
  "$invalid_secret_workspace_volume" \
  "$parent_home_volume" \
  "$malformed_config_home_volume" \
  "$malformed_config_workspace_volume" \
  "$symlink_config_home_volume" \
  "$symlink_config_workspace_volume"; do
  create_state_volume "$volume_name"
done

set_volume_root_metadata "$readonly_home_volume" 1000:1000 0700
set_volume_root_metadata "$readonly_workspace_volume" 1000:1000 0700

if ! state_volume_run "$parent_home_volume" '
  set -eu
  install -d -o codex -g codex -m 0700 /state/codex
'; then
  fail "could not seed the parent-only home volume"
fi

seed_state_volume "$home_volume" home 123:456 321:654 home-seed-content
seed_state_volume "$workspace_volume" workspaces 234:567 432:765 workspace-seed-content
seed_legacy_home_ssh_config "$home_volume"
seed_legacy_home_docker_config "$home_volume"
seed_state_volume "$invalid_secret_home_volume" invalid-home 345:678 543:876 invalid-home-seed
seed_state_volume "$invalid_secret_workspace_volume" invalid-workspaces 456:789 654:987 invalid-workspace-seed

if ! state_volume_run "$malformed_config_home_volume" '
  set -eu
  install -d -o 1000 -g 1000 -m 0700 /state/.docker
  printf "%s\n" "{not-json" > /state/.docker/config.json
  chown 1000:1000 /state/.docker/config.json
  chmod 0600 /state/.docker/config.json
'; then
  fail "could not seed the malformed Docker config fixture"
fi
if ! state_volume_run "$symlink_config_home_volume" '
  set -eu
  install -d -o 1000 -g 1000 -m 0700 /state/.docker
  ln -s /dev/null /state/.docker/config.json
  chown -h 1000:1000 /state/.docker/config.json
'; then
  fail "could not seed the symlink Docker config fixture"
fi

start_container() {
  local container_name="$1"
  local container_home_volume="$2"
  local container_workspace_volume="$3"
  local docker_host_bundle="${4:-$fixture_dir/docker-host}"
  local container_network="${5:-bridge}"

  docker run --detach \
    --name "$container_name" \
    --network "$container_network" \
    --publish 127.0.0.1::2222 \
    --env DOCKER_HOST=ssh://wrong-parent-environment/should-not-reach-ssh-sessions.sock \
    --env DOCKER_CONTEXT=wrong-parent-context \
    --env DOCKER_TLS_VERIFY=1 \
    --env DOCKER_CERT_PATH=/wrong-parent-docker-certs \
    --env TESTCONTAINERS_HOST_OVERRIDE=wrong-parent-testcontainers-host \
    --env TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/wrong-parent-docker.sock \
    --mount "type=bind,src=$fixture_dir/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
    --mount "type=bind,src=$fixture_dir/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
    --mount "type=bind,src=$docker_host_bundle,dst=/run/secrets/docker-host,readonly" \
    --mount "type=bind,src=$fixture_dir/ghcr,dst=/run/secrets/ghcr,readonly" \
    --mount "type=volume,src=$container_home_volume,dst=/home/codex,volume-nocopy" \
    --mount "type=volume,src=$container_workspace_volume,dst=/workspaces,volume-nocopy" \
    "$image" >/dev/null
}

wait_for_ssh() {
  local container_name="$1"
  local known_hosts_file="$2"
  local port
  local attempt

  port="$(docker port "$container_name" 2222/tcp | awk -F: 'NR == 1 { print $NF }')"
  [ -n "$port" ] || fail "could not resolve the published SSH port for $container_name"

  for attempt in $(seq 1 60); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$container_name")" != true ]; then
      docker logs "$container_name" >&2 || true
      fail "$container_name exited before SSH became ready"
    fi
    if ssh-keyscan -T 2 -p "$port" -t ed25519 127.0.0.1 > "$known_hosts_file" 2>/dev/null; then
      printf '%s\n' "$port"
      return 0
    fi
    sleep 0.5
  done

  docker logs "$container_name" >&2 || true
  fail "SSH did not become ready for $container_name"
}

ssh_command() {
  local known_hosts_file="$1"
  local port="$2"
  local identity_file="$3"
  local user="$4"
  shift 4

  ssh \
    -F /dev/null \
    -p "$port" \
    -i "$identity_file" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o IdentitiesOnly=yes \
    -o LogLevel=ERROR \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$known_hosts_file" \
    "${user}@127.0.0.1" \
    "$@"
}

assert_ssh_app_server_protocol() {
  local known_hosts_file="$1"
  local port="$2"

  # The fixture travels over the authenticated connection; direct exec would
  # bypass sshd's login environment. A second outer deadline bounds the client.
  [[ "$expected_codex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "app-server smoke requires an exact stable Codex version"
  ssh_command "$known_hosts_file" "$port" "$fixture_dir/client_key" codex \
    "timeout --signal=TERM --kill-after=5s 75s node - '$expected_codex_version'" \
    < "$script_dir/app-server-smoke.js" \
    || fail "authenticated SSH app-server protocol smoke failed"
}

expected_ssh_docker_environment() {
  local expected_host="$1"

  printf '%s\n' \
    "DOCKER_HOST=$docker_bridge_uri" \
    "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=$testcontainers_docker_socket_override" \
    "TESTCONTAINERS_HOST_OVERRIDE=$expected_host" \
    | LC_ALL=C sort
}

assert_ssh_docker_environment() {
  local known_hosts_file="$1"
  local port="$2"
  local expected_host="$3"
  local context="$4"
  local expected_environment
  local actual_environment

  expected_environment="$(expected_ssh_docker_environment "$expected_host")"
  actual_environment="$(
    ssh_command "$known_hosts_file" "$port" "$fixture_dir/client_key" codex \
      'env | LC_ALL=C awk -F= '\''$1 ~ /^(DOCKER_|TESTCONTAINERS_)/ { print }'\'' | LC_ALL=C sort'
  )" || fail "$context could not inspect the SSH Docker environment"
  if [ "$actual_environment" != "$expected_environment" ]; then
    printf 'smoke-test: expected SSH Docker environment:\n%s\n' \
      "$expected_environment" >&2
    printf 'smoke-test: actual SSH Docker environment:\n%s\n' \
      "$actual_environment" >&2
    fail "$context received an unexpected SSH Docker environment"
  fi
}

container_exact_process_pid() {
  local container_name="$1"
  local expected_cmdline="$2"

  docker exec "$container_name" /bin/sh -c '
    set -eu
    expected=$1
    count=0
    found=
    for process_dir in /proc/[0-9]*; do
      test -r "$process_dir/cmdline" || continue
      cmdline="$(tr "\000" " " < "$process_dir/cmdline" 2>/dev/null || true)"
      if test "$cmdline" = "$expected "; then
        count=$((count + 1))
        found=${process_dir##*/}
      fi
    done
    test "$count" -eq 1
    printf "%s\n" "$found"
  ' smoke-process "$expected_cmdline"
}

container_supervised_sshd_pid() {
  local container_name="$1"
  local supervisor_pid="$2"

  docker exec "$container_name" /bin/sh -c '
    set -eu
    supervisor_pid=$1
    count=0
    found=
    for process_dir in /proc/[0-9]*; do
      test -r "$process_dir/status" || continue
      test -e "$process_dir/exe" || continue
      test "$(readlink -f "$process_dir/exe" 2>/dev/null || true)" = /usr/sbin/sshd || continue
      parent="$(awk "\$1 == \"PPid:\" { print \$2 }" "$process_dir/status")"
      if test "$parent" = "$supervisor_pid"; then
        count=$((count + 1))
        found=${process_dir##*/}
      fi
    done
    test "$count" -eq 1
    printf "%s\n" "$found"
  ' smoke-supervised-sshd "$supervisor_pid"
}

bridge_ssh_child_count() {
  local container_name="$1"
  local remote_socket_path="$2"
  local bridge_pid

  bridge_pid="$(container_exact_process_pid \
    "$container_name" \
    "/usr/local/bin/node /usr/local/libexec/docker-bridge.js $remote_socket_path")" \
    || fail "could not identify the Docker bridge in $container_name"
  docker exec "$container_name" /bin/sh -c '
    set -eu
    bridge_pid=$1
    count=0
    for process_dir in /proc/[0-9]*; do
      test -r "$process_dir/status" || continue
      parent="$(awk "\$1 == \"PPid:\" { print \$2 }" "$process_dir/status")"
      if test "$parent" = "$bridge_pid"; then
        first_argument="$(tr "\000" "\n" < "$process_dir/cmdline" 2>/dev/null | sed -n "1p" || true)"
        test "$first_argument" = /usr/bin/ssh || exit 1
        count=$((count + 1))
      fi
    done
    printf "%s\n" "$count"
  ' smoke-bridge-children "$bridge_pid"
}

assert_bridge_runtime_contract() {
  local container_name="$1"
  local remote_socket_path="$2"
  local supervisor_pid
  local bridge_pid
  local sshd_pid

  supervisor_pid="$(container_exact_process_pid \
    "$container_name" \
    "/usr/local/bin/node /usr/local/libexec/supervisor.js $remote_socket_path")" \
    || fail "could not identify the service supervisor in $container_name"
  bridge_pid="$(container_exact_process_pid \
    "$container_name" \
    "/usr/local/bin/node /usr/local/libexec/docker-bridge.js $remote_socket_path")" \
    || fail "could not identify the Docker bridge in $container_name"
  sshd_pid="$(container_supervised_sshd_pid \
    "$container_name" \
    "$supervisor_pid")" \
    || fail "could not identify foreground OpenSSH in $container_name"

  docker exec "$container_name" /bin/sh -c '
    set -eu
    supervisor_pid=$1
    bridge_pid=$2
    sshd_pid=$3
    runtime_dir=$4
    socket_path=$5

    test "$(ps -o ppid= -p "$supervisor_pid" | tr -d " ")" = 1
    test "$(ps -o user= -p "$supervisor_pid" | tr -d " ")" = root
    test "$(ps -o ppid= -p "$bridge_pid" | tr -d " ")" = "$supervisor_pid"
    test "$(ps -o user= -p "$bridge_pid" | tr -d " ")" = codex
    test "$(ps -o ppid= -p "$sshd_pid" | tr -d " ")" = "$supervisor_pid"
    test "$(ps -o user= -p "$sshd_pid" | tr -d " ")" = root
    test "$(readlink -f "/proc/$supervisor_pid/exe")" = /usr/local/bin/node
    test "$(readlink -f "/proc/$sshd_pid/exe")" = /usr/sbin/sshd
    awk '\''
      $1 == "Groups:" { if (NF != 1) exit 1; groups = 1 }
      $1 == "CapEff:" { if ($2 !~ /^0+$/) exit 1; capabilities = 1 }
      $1 == "NoNewPrivs:" { if ($2 != 1) exit 1; no_new_privs = 1 }
      END { exit groups && capabilities && no_new_privs ? 0 : 1 }
    '\'' "/proc/$bridge_pid/status"
    sshd_cmdline="$(tr "\000" " " < "/proc/$sshd_pid/cmdline")"
    case "$sshd_cmdline" in
      *"-D -e -f /run/codex-remote-devbox/sshd_config"*) ;;
      *) exit 1 ;;
    esac

    test -d "$runtime_dir"
    test ! -L "$runtime_dir"
    test "$(stat -c "%u:%g:%a" -- "$runtime_dir")" = 1000:1000:700
    test -S "$socket_path"
    test ! -L "$socket_path"
    test "$(stat -c "%u:%g:%a" -- "$socket_path")" = 1000:1000:600
    awk -v expected="$socket_path" '\''
      $8 == expected { listeners++ }
      END { exit listeners == 1 ? 0 : 1 }
    '\'' /proc/net/unix
  ' smoke-bridge-runtime \
    "$supervisor_pid" \
    "$bridge_pid" \
    "$sshd_pid" \
    "$docker_bridge_runtime_dir" \
    "$docker_bridge_socket" \
    || {
      docker exec "$container_name" /bin/sh -c '
        supervisor_pid=$1
        bridge_pid=$2
        sshd_pid=$3
        runtime_dir=$4
        socket_path=$5
        ps -o pid=,ppid=,user=,comm= -p "$supervisor_pid,$bridge_pid,$sshd_pid" || true
        for process_pid in "$supervisor_pid" "$bridge_pid" "$sshd_pid"; do
          printf "pid=%s exe=%s cmdline=%s\n" \
            "$process_pid" \
            "$(readlink -f "/proc/$process_pid/exe" 2>/dev/null || true)" \
            "$(tr "\000" " " < "/proc/$process_pid/cmdline" 2>/dev/null || true)"
        done
        stat -c "runtime=%u:%g:%a:%F" -- "$runtime_dir" || true
        stat -c "socket=%u:%g:%a:%F" -- "$socket_path" || true
        awk -v expected="$socket_path" '\''$8 == expected { print "unix=" $0 }'\'' /proc/net/unix
      ' smoke-bridge-diagnostic \
        "$supervisor_pid" \
        "$bridge_pid" \
        "$sshd_pid" \
        "$docker_bridge_runtime_dir" \
        "$docker_bridge_socket" >&2 || true
      fail "$container_name violates the supervised Docker bridge runtime contract"
    }
}

wait_for_runtime_failure() {
  local container_name="$1"
  local log_file="$2"
  local expected_log="$3"
  local attempt
  local exit_code

  for attempt in $(seq 1 80); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$container_name")" != true ]; then
      exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$container_name")"
      docker logs "$container_name" >"$log_file" 2>&1 || true
      [ "$exit_code" -ne 0 ] \
        || fail "$container_name exited successfully after a supervised child failure"
      [ "$exit_code" -ne 137 ] \
        || fail "$container_name required SIGKILL after a supervised child failure"
      [ "$(docker inspect --format '{{.State.OOMKilled}}' "$container_name")" = false ] \
        || fail "$container_name was OOM-killed after a supervised child failure"
      grep -Fq "$expected_log" "$log_file" \
        || fail "$container_name did not report the supervised child failure"
      assert_log_excludes_key_material "$log_file"
      return 0
    fi
    sleep 0.25
  done

  docker logs "$container_name" >&2 || true
  fail "$container_name remained running after a supervised child failure"
}

start_fake_docker_backend() {
  if docker network inspect "$docker_backend_network" >/dev/null 2>&1; then
    fail "refusing to reuse a pre-existing smoke-test network: $docker_backend_network"
  fi
  docker network create "$docker_backend_network" >/dev/null

  docker run --detach \
    --name "$docker_backend_container" \
    --network "$docker_backend_network" \
    --network-alias "$docker_host_hostname" \
    --entrypoint /usr/sbin/sshd \
    --mount "type=bind,src=$fixture_dir/docker-backend,dst=/run/imageyard-backend,readonly" \
    --mount "type=bind,src=$script_dir/fake-docker-backend.py,dst=/usr/local/bin/docker,readonly" \
    "$image" \
    -D -e -f /run/imageyard-backend/sshd_config \
    >/dev/null

  for attempt in $(seq 1 40); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$docker_backend_container")" != true ]; then
      docker logs "$docker_backend_container" >&2 || true
      fail "the deterministic fake Docker SSH backend exited before readiness"
    fi
    if docker exec "$docker_backend_container" /bin/sh -c \
      'test "$(ss -H -lnt "sport = :2222" | wc -l)" -gt 0'; then
      return 0
    fi
    sleep 0.25
  done

  docker logs "$docker_backend_container" >&2 || true
  fail "the deterministic fake Docker SSH backend did not become ready"
}

assert_fake_backend_argv() {
  docker exec "$docker_backend_container" python3 -c '
import pathlib
import sys

records = pathlib.Path("/tmp/imageyard-fake-docker-argv.log").read_bytes().splitlines()
expected = [
    b"/usr/local/bin/docker",
    ("--host=unix://" + sys.argv[1]).encode("ascii"),
    b"system",
    b"dial-stdio",
]
if not records or any(record.split(b"\0") != expected for record in records):
    raise SystemExit(1)
' "$docker_remote_socket_path" \
    || fail "the fake Docker backend received unexpected remote command arguments"
}

assert_log_excludes_key_material() {
  local log_file="$1"
  local forbidden_material
  local grep_status
  local source_file

  for forbidden_material in \
    "$secret_marker" \
    "$docker_secret_marker" \
    "$authorized_key_material" \
    "$host_public_key_material" \
    "$docker_client_public_key_material" \
    "$docker_remote_host_public_key_material" \
    "$docker_client_fingerprint" \
    "$docker_remote_host_fingerprint" \
    "$docker_host_uri" \
    "$ghcr_pat_marker"; do
    grep_status=0
    grep -Fq -- "$forbidden_material" "$log_file" >/dev/null 2>&1 || grep_status=$?
    case "$grep_status" in
      0) fail "log contains runtime key fixture material: $log_file" ;;
      1) ;;
      *) fail "could not scan log for runtime key fixture material: $log_file" ;;
    esac
  done

  for source_file in "${secret_source_files[@]}"; do
    [ -s "$source_file" ] || continue
    grep_status=0
    grep -F -f "$source_file" "$log_file" >/dev/null 2>&1 || grep_status=$?
    case "$grep_status" in
      0) fail "log contains runtime key fixture material: $log_file" ;;
      1) ;;
      *) fail "could not scan log for runtime key fixture material: $log_file" ;;
    esac
  done

  for source_file in "${sensitive_docker_host_files[@]}"; do
    [ -s "$source_file" ] || continue
    grep_status=0
    grep -F -f "$source_file" "$log_file" >/dev/null 2>&1 || grep_status=$?
    case "$grep_status" in
      0) fail "log contains Docker host fixture material: $log_file" ;;
      1) ;;
      *) fail "could not scan log for Docker host fixture material: $log_file" ;;
    esac
  done


  for source_file in "${ghcr_source_files[@]}"; do
    [ -s "$source_file" ] || continue
    grep_status=0
    grep -F -f "$source_file" "$log_file" >/dev/null 2>&1 || grep_status=$?
    case "$grep_status" in
      0) fail "log contains GHCR Secret material: $log_file" ;;
      1) ;;
      *) fail "could not scan log for GHCR Secret material: $log_file" ;;
    esac
  done
}

wait_for_start_failure() {
  local container_name="$1"
  local log_file="$2"
  local expected_log="$3"
  local attempt
  local exit_code

  for attempt in $(seq 1 20); do
    if [ "$(docker inspect --format '{{.State.Running}}' "$container_name")" != true ]; then
      exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$container_name")"
      docker logs "$container_name" >"$log_file" 2>&1 || true
      [ "$exit_code" -ne 0 ] || fail "$container_name exited successfully instead of failing closed"
      if grep -Fq "$secret_marker" "$log_file"; then
        fail "$container_name printed runtime key material"
      fi
      assert_log_excludes_key_material "$log_file"
      grep -Fq "$expected_log" "$log_file" \
        || fail "$container_name did not report the expected failure: $expected_log"
      return 0
    fi
    sleep 0.25
  done

  docker logs "$container_name" >"$log_file" 2>&1 || true
  if grep -Fq "$secret_marker" "$log_file"; then
    fail "$container_name printed runtime key material"
  fi
  assert_log_excludes_key_material "$log_file"
  fail "$container_name remained running instead of failing closed"
}

expect_start_failure() {
  local container_name="$1"
  local log_file="$2"
  local expected_log="$3"
  local docker_bundle_mount
  local ghcr_bundle_mount
  shift 3

  docker_bundle_mount="${docker_host_failure_mount:-type=bind,src=$fixture_dir/docker-host,dst=/run/secrets/docker-host,readonly}"
  ghcr_bundle_mount="${ghcr_failure_mount:-type=bind,src=$fixture_dir/ghcr,dst=/run/secrets/ghcr,readonly}"

  if ! docker run --detach \
    --name "$container_name" \
    --mount "$docker_bundle_mount" \
    --mount "$ghcr_bundle_mount" \
    "$@" \
    "$image" \
    > /dev/null 2>"$log_file"; then
    fail "Docker could not create $container_name"
  fi

  wait_for_start_failure "$container_name" "$log_file" "$expected_log"
}

expect_state_type_failure() {
  local container_name="$1"
  local log_file="$2"
  local state_root="$3"
  local state_type="$4"
  shift 4
  local expected_log
  local wrapper
  local docker_bundle_mount
  local ghcr_bundle_mount

  case "$state_type" in
    missing)
      expected_log="required state root is missing: $state_root"
      wrapper='set -eu; target=$1; cd /; rm -rf -- "$target"; exec /usr/local/bin/codex-remote-devbox-entrypoint'
      ;;
    file)
      expected_log="required state root is not a directory: $state_root"
      wrapper='set -eu; target=$1; cd /; rm -rf -- "$target"; : > "$target"; exec /usr/local/bin/codex-remote-devbox-entrypoint'
      ;;
    symlink)
      expected_log="required state root is a symbolic link: $state_root"
      wrapper='set -eu; target=$1; cd /; rm -rf -- "$target"; ln -s /tmp "$target"; exec /usr/local/bin/codex-remote-devbox-entrypoint'
      ;;
    *)
      fail "unsupported state type fixture: $state_type"
      ;;
  esac

  docker_bundle_mount="${docker_host_failure_mount:-type=bind,src=$fixture_dir/docker-host,dst=/run/secrets/docker-host,readonly}"
  ghcr_bundle_mount="${ghcr_failure_mount:-type=bind,src=$fixture_dir/ghcr,dst=/run/secrets/ghcr,readonly}"

  if ! docker run --detach \
    --name "$container_name" \
    --mount "$docker_bundle_mount" \
    --mount "$ghcr_bundle_mount" \
    "$@" \
    --entrypoint /bin/sh \
    "$image" \
    -c "$wrapper" smoke-state "$state_root" \
    > /dev/null 2>"$log_file"; then
    fail "Docker could not create $container_name"
  fi

  wait_for_start_failure "$container_name" "$log_file" "$expected_log"
}

copy_docker_host_bundle_fixture() {
  local fixture_name="$1"
  local destination="$fixture_dir/docker-host-$fixture_name"

  mkdir -p "$destination"
  cp -a "$fixture_dir/docker-host/." "$destination/"
  printf '%s\n' "$destination"
}

write_docker_host_fixture_field() {
  local bundle_dir="$1"
  local field_name="$2"
  local field_value="$3"
  local field_mode=0444

  if [ "$field_name" = ssh_client_ed25519_private_key ]; then
    field_mode=0400
  fi
  chmod u+w "$bundle_dir/$field_name"
  printf '%s\n' "$field_value" > "$bundle_dir/$field_name"
  chmod "$field_mode" "$bundle_dir/$field_name"
}

copy_docker_host_fixture_private_key() {
  local bundle_dir="$1"
  local source_key="$2"

  chmod u+w "$bundle_dir/ssh_client_ed25519_private_key"
  cp "$source_key" "$bundle_dir/ssh_client_ed25519_private_key"
  chmod 0400 "$bundle_dir/ssh_client_ed25519_private_key"
}

expect_docker_host_bundle_failure() {
  local fixture_name="$1"
  local bundle_dir="$2"
  local expected_log="$3"
  local container_name="${name_prefix}-docker-${fixture_name}"
  local log_file="$fixture_dir/docker-${fixture_name}.log"

  cleanup_containers+=("$container_name")
  docker_host_failure_mount="type=bind,src=$bundle_dir,dst=/run/secrets/docker-host,readonly" \
    expect_start_failure \
      "$container_name" \
      "$log_file" \
      "$expected_log" \
      --network none \
      --mount "type=bind,src=$fixture_dir/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
      --mount "type=bind,src=$fixture_dir/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
      --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
      --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"

  local sensitive_name
  local grep_status
  for sensitive_name in \
    docker_host \
    ssh_client_ed25519_private_key \
    ssh_client_ed25519_fingerprint \
    ssh_host_ed25519_fingerprint \
    ssh_known_hosts; do
    [ -f "$bundle_dir/$sensitive_name" ] || continue
    [ ! -L "$bundle_dir/$sensitive_name" ] || continue
    [ -s "$bundle_dir/$sensitive_name" ] || continue
    grep_status=0
    grep -F -f "$bundle_dir/$sensitive_name" "$log_file" >/dev/null 2>&1 \
      || grep_status=$?
    case "$grep_status" in
      0) fail "$container_name printed Docker host Secret material" ;;
      1) ;;
      *) fail "could not scan $container_name logs for Docker host Secret material" ;;
    esac
  done
}

copy_ghcr_bundle_fixture() {
  local fixture_name="$1"
  local destination="$fixture_dir/ghcr-$fixture_name"

  mkdir -p "$destination"
  cp -a "$fixture_dir/ghcr/." "$destination/"
  printf '%s\n' "$destination"
}

write_ghcr_fixture_field() {
  local bundle_dir="$1"
  local field_name="$2"
  local field_value="$3"
  local field_mode=0444

  if [ "$field_name" = ghcr_pat ]; then
    field_mode=0400
  fi
  chmod u+w "$bundle_dir/$field_name"
  printf '%s' "$field_value" > "$bundle_dir/$field_name"
  chmod "$field_mode" "$bundle_dir/$field_name"
}

expect_ghcr_bundle_failure() {
  local fixture_name="$1"
  local bundle_dir="$2"
  local expected_log="$3"
  local container_name="${name_prefix}-ghcr-${fixture_name}"
  local log_file="$fixture_dir/ghcr-${fixture_name}.log"

  cleanup_containers+=("$container_name")
  ghcr_failure_mount="type=bind,src=$bundle_dir,dst=/run/secrets/ghcr,readonly" \
    expect_start_failure \
      "$container_name" \
      "$log_file" \
      "$expected_log" \
      --network none \
      --mount "type=bind,src=$fixture_dir/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
      --mount "type=bind,src=$fixture_dir/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
      --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
      --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"

  if [ -f "$bundle_dir/ghcr_pat" ] \
    && [ ! -L "$bundle_dir/ghcr_pat" ] \
    && [ -s "$bundle_dir/ghcr_pat" ]; then
    grep_status=0
    LC_ALL=C grep -F -f "$bundle_dir/ghcr_pat" "$log_file" >/dev/null 2>&1 || grep_status=$?
    case "$grep_status" in
      0) fail "$container_name printed GHCR PAT material" ;;
      1) ;;
      *) fail "could not scan $container_name logs for GHCR PAT material" ;;
    esac
  fi
}

assert_container_state_contract() {
  local container_name="$1"

  docker exec "$container_name" /bin/sh -c '
    set -eu
    for state_root in /home/codex /workspaces; do
      awk -v expected="$state_root" '\''
        $5 == expected { found = 1 }
        END { exit found ? 0 : 1 }
      '\'' /proc/self/mountinfo
      test ! -L "$state_root"
      test -d "$state_root"
      test "$(stat -c "%u:%g:%a" -- "$state_root")" = 1000:1000:700
    done
  '
}

docker image inspect "$image" > "$fixture_dir/image-inspect.json"
if grep -Fq "$secret_marker" "$fixture_dir/image-inspect.json" \
  || grep -Fq "$docker_secret_marker" "$fixture_dir/image-inspect.json" \
  || grep -Fq "$ghcr_pat_marker" "$fixture_dir/image-inspect.json"; then
  fail "image metadata contains the smoke-test secret marker"
fi
if docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  | grep -E '^(DOCKER_|TESTCONTAINERS_)' >/dev/null; then
  fail "image metadata sets Docker or Testcontainers runtime variables"
fi
docker history --no-trunc "$image" > "$fixture_dir/image-history.txt"
if grep -Fq "$secret_marker" "$fixture_dir/image-history.txt" \
  || grep -Fq "$docker_secret_marker" "$fixture_dir/image-history.txt" \
  || grep -Fq "$ghcr_pat_marker" "$fixture_dir/image-history.txt"; then
  fail "image history contains the smoke-test secret marker"
fi

docker create --name "$audit_container" --entrypoint /bin/sh "$image" -c true >/dev/null
docker export "$audit_container" > "$fixture_dir/rootfs.tar"
tar -tf "$fixture_dir/rootfs.tar" > "$fixture_dir/rootfs.list"
if grep -E '(^|/)(ssh_host_[^/]*_key|authorized_keys|ssh_client_ed25519_private_key|ssh_known_hosts)$' \
  "$fixture_dir/rootfs.list" >/dev/null; then
  fail "image filesystem contains a runtime SSH key or pin"
fi
if ! docker run --rm \
  --name "$filesystem_audit_container" \
  --entrypoint /bin/sh \
  "$image" \
  -c '
    set -eu
    test ! -e /home/codex/.codex/auth.json
    test ! -e /home/codex/.config/gh/hosts.yml
    if find /etc/ssh /home/codex /root /run -type f -exec grep -I -l -E "^-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----" {} + 2>/dev/null | grep -q .; then
      exit 1
    fi
    for forbidden_material in "$@"; do
      if grep -R -F -l "$forbidden_material" /etc /home /root /run /usr/local 2>/dev/null | grep -q .; then
        exit 1
      fi
    done
  ' sh "$secret_marker" "$docker_secret_marker" "$ghcr_pat_marker"; then
  fail "image filesystem contains credential material or the smoke-test marker"
fi

start_fake_docker_backend
start_container \
  "$primary_container" \
  "$home_volume" \
  "$workspace_volume" \
  "$fixture_dir/docker-host" \
  "$docker_backend_network"
primary_known_hosts="$fixture_dir/known_hosts.primary"
primary_port="$(wait_for_ssh "$primary_container" "$primary_known_hosts")"
primary_fingerprint="$(ssh-keygen -E sha256 -lf "$primary_known_hosts" | awk 'NR == 1 { print $2 }')"
[ -n "$primary_fingerprint" ] || fail "could not read the primary host fingerprint"

[ "$(docker inspect --format '{{.HostConfig.Privileged}}' "$primary_container")" = false ] \
  || fail "container unexpectedly requires privileged mode"
[ "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" = SIGTERM ] \
  || fail "image stop signal is not SIGTERM"
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/tini","-g","--","/usr/local/bin/codex-remote-devbox-entrypoint"]' ] \
  || fail "image entrypoint does not preserve the tini -g process contract"
[ "$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$image")" = '{"2222/tcp":{}}' ] \
  || fail "image exposes a port other than TCP 2222"

actual_mounts="$(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$primary_container" | sed '/^$/d' | sort)"
expected_mounts="$(printf '%s\n' /home/codex /run/secrets/docker-host /run/secrets/ghcr /run/secrets/ssh-access/authorized_keys /run/secrets/ssh-host/ssh_host_ed25519_key /workspaces | sort)"
[ "$actual_mounts" = "$expected_mounts" ] \
  || fail "container uses unexpected mounts: $(printf '%s' "$actual_mounts" | paste -sd, -)"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/codex"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$primary_container")" = "volume:$home_volume" ] \
  || fail "home state is not backed by the expected named volume"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/workspaces"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$primary_container")" = "volume:$workspace_volume" ] \
  || fail "workspace state is not backed by the expected named volume"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/run/secrets/docker-host"}}{{.Type}}:{{.RW}}{{end}}{{end}}' "$primary_container")" = bind:false ] \
  || fail "Docker host Secret is not a read-only bind mount"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/run/secrets/ghcr"}}{{.Type}}:{{.RW}}{{end}}{{end}}' "$primary_container")" = bind:false ] \
  || fail "GHCR Secret is not a read-only bind mount"

assert_container_state_contract "$primary_container"
assert_volume_root_metadata "$home_volume" 1000:1000:700
assert_volume_root_metadata "$workspace_volume" 1000:1000:700
assert_seed_preserved "$home_volume" home 123:456 321:654 home-seed-content
assert_seed_preserved "$workspace_volume" workspaces 234:567 432:765 workspace-seed-content
assert_legacy_home_ssh_config_preserved "$home_volume"
assert_home_docker_config_enabled "$home_volume" present
assert_no_probe_leftovers "$home_volume"
assert_no_probe_leftovers "$workspace_volume"
assert_volume_top_level_entries "$home_volume" .docker .ssh seed-home
assert_volume_top_level_entries "$workspace_volume" seed-workspaces

docker exec "$primary_container" /bin/sh -c '
  set -eu
  test "$(ps -o comm= -p 1 | tr -d " ")" = tini
  test "$(tr "\000" " " < /proc/1/cmdline)" = "/usr/bin/tini -g -- /usr/local/bin/codex-remote-devbox-entrypoint "
  for forbidden_socket in \
    /run/docker.sock \
    /var/run/docker.sock \
    /run/containerd/containerd.sock \
    /var/run/containerd/containerd.sock; do
    test ! -S "$forbidden_socket"
  done
  for forbidden_process in dockerd containerd containerd-shim podman conmon nerdctl; do
    if pgrep -x "$forbidden_process" >/dev/null 2>&1; then
      exit 1
    fi
  done
'
assert_bridge_runtime_contract "$primary_container" "$docker_remote_socket_path"

docker exec "$primary_container" /bin/sh -c '
  set -eu
  test "$DOCKER_HOST" = ssh://wrong-parent-environment/should-not-reach-ssh-sessions.sock
  test "$DOCKER_CONTEXT" = wrong-parent-context
  test "$DOCKER_TLS_VERIFY" = 1
  test "$DOCKER_CERT_PATH" = /wrong-parent-docker-certs
  test "$TESTCONTAINERS_HOST_OVERRIDE" = wrong-parent-testcontainers-host
  test "$TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE" = /wrong-parent-docker.sock
' || fail "docker exec did not preserve the deliberately hostile container-spec environment"

docker exec "$primary_container" /bin/sh -c '
  set -eu
  source_dir=/run/secrets/docker-host
  runtime_dir=/run/codex-remote-devbox/docker-host
  client_key=ssh_client_ed25519_private_key
  known_hosts=ssh_known_hosts

  test -d "$source_dir"
  test ! -L "$source_dir"
  awk -v expected="$source_dir" '\''
    $5 == expected && $6 ~ /(^|,)ro(,|$)/ { found = 1 }
    END { exit found ? 0 : 1 }
  '\'' /proc/self/mountinfo
  for source_name in \
    docker_host \
    ssh_alias \
    ssh_host \
    ssh_port \
    ssh_user \
    ssh_client_ed25519_private_key \
    ssh_client_ed25519_fingerprint \
    ssh_host_ed25519_fingerprint \
    ssh_known_hosts; do
    source_file="$source_dir/$source_name"
    test -f "$source_file"
    test ! -L "$source_file"
    test -s "$source_file"
    expected_mode=444
    if test "$source_name" = "$client_key"; then
      expected_mode=400
    fi
    test "$(stat -c "%a" -- "$source_file")" = "$expected_mode"
    if sudo -n -u codex -- test -w "$source_file"; then
      exit 1
    fi
  done

  test -f "$runtime_dir/$client_key"
  test ! -L "$runtime_dir/$client_key"
  test -f "$runtime_dir/$known_hosts"
  test ! -L "$runtime_dir/$known_hosts"
  test "$(stat -c "%u:%g:%a" -- "$runtime_dir/$client_key")" = 1000:1000:600
  test "$(stat -c "%u:%g:%a" -- "$runtime_dir/$known_hosts")" = 1000:1000:600
  cmp "$source_dir/$client_key" "$runtime_dir/$client_key"
  cmp "$source_dir/$known_hosts" "$runtime_dir/$known_hosts"
  test "$(stat -c "%u:%g:%a" -- /etc/ssh/ssh_config.d/20-codex-docker-host.conf)" = 0:0:644
  test "$(stat -c "%u:%g:%a" -- /run/codex-remote-devbox/sshd_config)" = 0:0:600

  client_config=/etc/ssh/ssh_config.d/20-codex-docker-host.conf
  test "$(grep -Ec "^Host[[:space:]]+docker-host$" "$client_config")" = 1
  test "$(grep -Ec "^Host[[:space:]]" "$client_config")" = 1
  grep -Fxq "  HostKeyAlias docker-host" "$client_config"
  home_effective="$(sudo -n -H -u codex -- ssh -G docker-host 2>/dev/null)"
  printf "%s\n" "$home_effective" | grep -Fxq "hostname adversarial-home.invalid"
  printf "%s\n" "$home_effective" | grep -Fxq "user adversarial-user"
  printf "%s\n" "$home_effective" | grep -Fxq "port 1"
  printf "%s\n" "$home_effective" | grep -Fxq "proxycommand false"

  effective="$(sudo -n -H -u codex -- ssh -G -F /etc/ssh/ssh_config docker-host 2>/dev/null)"
  has_setting() {
    printf "%s\n" "$effective" | grep -Fxq -- "$1"
  }
  has_setting "host docker-host"
  has_setting "hostname $1"
  has_setting "user $2"
  has_setting "port $3"
  has_setting "identityfile $runtime_dir/$client_key"
  has_setting "identitiesonly yes"
  has_setting "batchmode yes"
  has_setting "connecttimeout 10"
  has_setting "preferredauthentications publickey"
  has_setting "passwordauthentication no"
  has_setting "kbdinteractiveauthentication no"
  has_setting "stricthostkeychecking true"
  has_setting "userknownhostsfile $runtime_dir/$known_hosts"
  has_setting "hostkeyalgorithms ssh-ed25519"
  has_setting "hostkeyalias docker-host"
  has_setting "updatehostkeys false"
  has_setting "forwardagent no"

  test "$(grep -Ec "^SetEnv[[:space:]]" /run/codex-remote-devbox/sshd_config)" = 1
  grep -Fxq "SetEnv DOCKER_HOST=$4 TESTCONTAINERS_HOST_OVERRIDE=$1 TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=$5" \
    /run/codex-remote-devbox/sshd_config
  if grep -Fq "$6" /run/codex-remote-devbox/sshd_config; then
    exit 1
  fi
  /usr/sbin/sshd -t -f /run/codex-remote-devbox/sshd_config
' sh \
  "$docker_host_hostname" \
  "$docker_host_user" \
  "$docker_host_port" \
  "$docker_bridge_uri" \
  "$testcontainers_docker_socket_override" \
  "$docker_host_uri"

assert_home_docker_config_enabled "$home_volume" present

docker exec "$primary_container" /bin/sh -c '
  set -eu
  source_dir=/run/secrets/ghcr
  runtime_dir=/run/codex-remote-devbox/ghcr
  runtime_pat_marker=$1

  test -d "$source_dir"
  test ! -L "$source_dir"
  awk -v expected="$source_dir" '\''
    $5 == expected && $6 ~ /(^|,)ro(,|$)/ { found = 1 }
    END { exit found ? 0 : 1 }
  '\'' /proc/self/mountinfo
  for source_name in ghcr_username ghcr_pat; do
    source_file="$source_dir/$source_name"
    test -f "$source_file"
    test ! -L "$source_file"
    test -s "$source_file"
    expected_mode=444
    if test "$source_name" = ghcr_pat; then
      expected_mode=400
    fi
    test "$(stat -c "%u:%g:%a" -- "$source_file")" = "0:0:$expected_mode"
    if sudo -n -u codex -- test -w "$source_file"; then
      exit 1
    fi
  done

  test ! -L "$runtime_dir"
  test "$(stat -c "%u:%g:%a" -- "$runtime_dir")" = 1000:1000:700
  test "$(find "$runtime_dir" -mindepth 1 -maxdepth 1 -printf "%f\n" | sort | tr "\n" " ")" = "ghcr_pat ghcr_username "
  for runtime_name in ghcr_username ghcr_pat; do
    runtime_file="$runtime_dir/$runtime_name"
    test -f "$runtime_file"
    test ! -L "$runtime_file"
    test "$(stat -c "%u:%g:%a:%h" -- "$runtime_file")" = 1000:1000:600:1
    cmp "$source_dir/$runtime_name" "$runtime_file"
  done
  test "$(stat -c "%u:%g:%a" -- /usr/local/bin/docker-credential-codex-ghcr)" = 0:0:755
  test "$(stat -c "%u:%g:%a" -- /usr/local/bin/codex-ghcr-auth)" = 0:0:755
  test "$(stat -c "%u:%g:%a" -- /usr/local/libexec/ghcr-auth-config.js)" = 0:0:644
  test "$(stat -c "%u:%g:%a:%h" -- /run/codex-remote-devbox/ghcr-auth.lock)" = 1000:1000:600:1

  printf "%s" ghcr.io \
    | sudo -n -u codex -- /usr/local/bin/docker-credential-codex-ghcr get \
    | sudo -n -u codex -- node -e '\''
      const fs = require("node:fs");
      const chunks = [];
      process.stdin.on("data", (chunk) => chunks.push(chunk));
      process.stdin.on("end", () => {
        const actual = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        const username = fs.readFileSync("/run/codex-remote-devbox/ghcr/ghcr_username", "ascii");
        const secret = fs.readFileSync("/run/codex-remote-devbox/ghcr/ghcr_pat", "ascii");
        if (actual.Username !== username || actual.Secret !== secret) process.exit(1);
      });
    '\''
  printf "%s" "{}" \
    | sudo -n -u codex -- /usr/local/bin/docker-credential-codex-ghcr store \
      > /tmp/ghcr-helper.stdout 2> /tmp/ghcr-helper.stderr \
    && exit 1
  test ! -s /tmp/ghcr-helper.stdout
  grep -Fxq "docker-credential-codex-ghcr: credential operation failed" /tmp/ghcr-helper.stderr
  if grep -Fq -- "$runtime_pat_marker" /tmp/ghcr-helper.stderr; then
    exit 1
  fi
  rm -f /tmp/ghcr-helper.stdout /tmp/ghcr-helper.stderr

  assert_helper_failure() {
    input_file=$1
    shift
    set +e
    "$@" < "$input_file" \
      > /tmp/ghcr-helper.stdout 2> /tmp/ghcr-helper.stderr
    helper_status=$?
    set -e
    test "$helper_status" -ne 0
    test ! -s /tmp/ghcr-helper.stdout
    grep -Fxq "docker-credential-codex-ghcr: credential operation failed" \
      /tmp/ghcr-helper.stderr
    if grep -Fq -- "$runtime_pat_marker" /tmp/ghcr-helper.stderr; then
      exit 1
    fi
    rm -f /tmp/ghcr-helper.stdout /tmp/ghcr-helper.stderr "$input_file"
  }

  printf "%s" docker.io > /tmp/ghcr-helper.input
  assert_helper_failure \
    /tmp/ghcr-helper.input \
    sudo -n -u codex -- /usr/local/bin/docker-credential-codex-ghcr get

  printf "%s" ghcr.io > /tmp/ghcr-helper.input
  assert_helper_failure \
    /tmp/ghcr-helper.input \
    /usr/local/bin/docker-credential-codex-ghcr get

  head -c 1048576 /dev/zero | tr "\\000" x > /tmp/ghcr-helper.input
  assert_helper_failure \
    /tmp/ghcr-helper.input \
    sudo -n -u codex -- /usr/local/bin/docker-credential-codex-ghcr get

  chmod 0644 "$runtime_dir/ghcr_pat"
  printf "%s" ghcr.io > /tmp/ghcr-helper.input
  assert_helper_failure \
    /tmp/ghcr-helper.input \
    sudo -n -u codex -- /usr/local/bin/docker-credential-codex-ghcr get
  chmod 0600 "$runtime_dir/ghcr_pat"
' sh "$ghcr_pat_marker"

clean_stdout="$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "printf '%s' codex-smoke-output" 2>"$fixture_dir/ssh.stderr")"
[ "$clean_stdout" = codex-smoke-output ] || fail "noninteractive SSH stdout contains a banner or MOTD"
assert_log_excludes_key_material "$fixture_dir/ssh.stderr"

[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'id -u')" = 1000 ] \
  || fail "SSH session UID is not 1000"
[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'id -g')" = 1000 ] \
  || fail "SSH session GID is not 1000"
[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "getent passwd codex | cut -d: -f7")" = /bin/bash ] \
  || fail "codex login shell is not Bash"
[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'sudo -n id -u')" = 0 ] \
  || fail "passwordless sudo is unavailable"

assert_ssh_docker_environment \
  "$primary_known_hosts" \
  "$primary_port" \
  "$docker_host_hostname" \
  "command SSH session"

interactive_probe_output="$fixture_dir/interactive-docker-env.stdout"
interactive_probe_error="$fixture_dir/interactive-docker-env.stderr"
if ! {
  printf '%s\n' \
    'export HISTFILE=/dev/null' \
    'set -eu' \
    "test \"\${DOCKER_HOST-}\" = '$docker_bridge_uri'" \
    "test \"\${TESTCONTAINERS_HOST_OVERRIDE-}\" = '$docker_host_hostname'" \
    "test \"\${TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE-}\" = '$testcontainers_docker_socket_override'" \
    'test -z "${DOCKER_CONTEXT+x}"' \
    'test -z "${DOCKER_TLS_VERIFY+x}"' \
    'test -z "${DOCKER_CERT_PATH+x}"' \
    'printf "%s\\n" docker-env-interactive-ok' \
    'exit'
} | ssh \
  -F /dev/null \
  -tt \
  -p "$primary_port" \
  -i "$fixture_dir/client_key" \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o IdentitiesOnly=yes \
  -o LogLevel=ERROR \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$primary_known_hosts" \
  codex@127.0.0.1 \
  >"$interactive_probe_output" 2>"$interactive_probe_error"; then
  fail "interactive SSH session could not validate the Docker environment"
fi
grep -Fq docker-env-interactive-ok "$interactive_probe_output" \
  || fail "interactive SSH session did not receive DOCKER_HOST"
assert_log_excludes_key_material "$interactive_probe_output"
assert_log_excludes_key_material "$interactive_probe_error"
for hostile_value in \
  wrong-parent-context \
  wrong-parent-testcontainers-host \
  wrong-parent-docker.sock \
  wrong-parent-docker-certs; do
  if grep -Fq "$hostile_value" "$interactive_probe_output" \
    || grep -Fq "$hostile_value" "$interactive_probe_error"; then
    fail "interactive SSH session inherited hostile container-spec environment"
  fi
done

client_smoke_output="$(
  ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
    'node -' < "$script_dir/docker-bridge-client-smoke.js"
)" || fail "the deterministic Docker bridge client smoke failed"
client_daemon_id="${client_smoke_output##* }"
[ "$client_daemon_id" = "$fake_docker_daemon_id" ] \
  || fail "the bridge client did not reach the expected fake Docker daemon"
cli_daemon_id="$(
  ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
    "docker info --format '{{.ID}}'"
)" || fail "Docker CLI could not use the local Unix bridge"
[ "$cli_daemon_id" = "$client_daemon_id" ] \
  || fail "Docker CLI and the bridge client reached different daemon IDs"

if ! ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "docker pull '$ghcr_pull_image'" \
  > "$fixture_dir/ghcr-pull.stdout" 2> "$fixture_dir/ghcr-pull.stderr"; then
  cat "$fixture_dir/ghcr-pull.stderr" >&2
  fail "Docker CLI could not authenticate the deterministic private GHCR pull"
fi
assert_log_excludes_key_material "$fixture_dir/ghcr-pull.stdout"
assert_log_excludes_key_material "$fixture_dir/ghcr-pull.stderr"
[ "$(docker exec "$docker_backend_container" /bin/sh -c \
  'grep -Fxc authenticated-ghcr-pull /tmp/imageyard-fake-docker-auth.log')" = 1 ] \
  || fail "the fake Docker daemon did not receive exactly one helper-authenticated pull"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'set -eu
   ready=/tmp/imageyard-ghcr-lock-ready
   rm -f "$ready"
   /usr/bin/flock \
     --exclusive \
     /run/codex-remote-devbox/ghcr-auth.lock \
     /bin/sh -c "touch $ready; sleep 2" &
   holder_pid=$!
   for attempt in $(seq 1 100); do
     test -e "$ready" && break
     sleep 0.02
   done
   test -e "$ready"
   codex-ghcr-auth scrub-legacy-auth &
   scrub_pid=$!
   codex-ghcr-auth disable &
   disable_pid=$!
   sleep 0.2
   kill -0 "$scrub_pid"
   kill -0 "$disable_pid"
   wait "$holder_pid"
   wait "$scrub_pid"
   wait "$disable_pid"
   rm -f "$ready"' \
  || fail "concurrent GHCR configuration actions did not serialize through the runtime lock"
if ! state_volume_run "$home_volume" '
  set -eu
  jq -e '\''
    (.credHelpers | has("ghcr.io") | not) and
    .credHelpers["registry.example.test"] == "pass" and
    (.auths | has("ghcr.io") | not) and
    .auths["registry.example.test"].auth == "dW5yZWxhdGVkOnByZXNlcnZlZA==" and
    .currentContext == "preserved-context" and
    .plugins.buildx.enabled == "true"
  '\'' /state/.docker/config.json >/dev/null
'; then
  fail "the managed GHCR helper disable changed unrelated Docker configuration"
fi
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'codex-ghcr-auth scrub-legacy-auth && \
   codex-ghcr-auth scrub-legacy-auth && \
   codex-ghcr-auth disable && \
   codex-ghcr-auth disable' \
  || fail "the explicit GHCR scrub and disable operations are not idempotent"
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'codex-ghcr-auth enable && codex-ghcr-auth enable' \
  || fail "the managed GHCR helper re-enable operation failed"
assert_home_docker_config_enabled "$home_volume" absent
home_docker_config_metadata_before_restart="$(record_home_docker_config_metadata "$home_volume")"

direct_ssh_daemon_id="$(
  docker exec "$primary_container" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    LANG=C.UTF-8 \
    "DOCKER_HOST=$docker_host_uri" \
    /bin/sh -c '
    set -eu
    test "$HOME" = /root
    test "$DOCKER_HOST" = "$1"
    test -z "${DOCKER_CONFIG+x}"
    test -z "${DOCKER_CONTEXT+x}"
    test -z "${DOCKER_TLS_VERIFY+x}"
    test -z "${DOCKER_CERT_PATH+x}"
    test -z "${TESTCONTAINERS_HOST_OVERRIDE+x}"
    test -z "${TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE+x}"
    test ! -e /root/.ssh/config
    test -r /etc/ssh/ssh_config.d/20-codex-docker-host.conf
    docker info --format "{{.ID}}"
  ' direct-docker-ssh "$docker_host_uri"
)" || fail "the validated path-bearing Docker SSH URI could not reach the fake daemon"
[ "$direct_ssh_daemon_id" = "$client_daemon_id" ] \
  || fail "the direct Docker SSH connhelper and local bridge reached different daemon IDs"
assert_fake_backend_argv
for attempt in $(seq 1 40); do
  if [ "$(bridge_ssh_child_count "$primary_container" "$docker_remote_socket_path")" = 0 ]; then
    break
  fi
  sleep 0.25
done
[ "$(bridge_ssh_child_count "$primary_container" "$docker_remote_socket_path")" = 0 ] \
  || fail "bridge transports remained after deterministic client exercises"

bridge_hold_output="$fixture_dir/bridge-hold.stdout"
bridge_hold_error="$fixture_dir/bridge-hold.stderr"
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'exec node -e '"'"'const net=require("node:net");const target=process.env.DOCKER_HOST;const socket=net.createConnection({path:target.slice("unix://".length),allowHalfOpen:true},()=>{socket.write(Buffer.from("POST /hijack HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n"));process.stdout.write("bridge-hold-ready:"+process.pid+"\n");});socket.on("data",()=>{});socket.on("error",()=>process.exit(1));setInterval(()=>{},1000);'"'"'' \
  >"$bridge_hold_output" 2>"$bridge_hold_error" &
bridge_hold_pid=$!
bridge_hold_ready=false
for attempt in $(seq 1 40); do
  if ! kill -0 "$bridge_hold_pid" >/dev/null 2>&1; then
    break
  fi
  if grep -Fq bridge-hold-ready "$bridge_hold_output" 2>/dev/null; then
    bridge_hold_ready=true
    break
  fi
  sleep 0.25
done
[ "$bridge_hold_ready" = true ] \
  || fail "could not hold a Docker bridge connection for argv inspection"
bridge_remote_hold_pid="$(sed -nE 's/^bridge-hold-ready:([0-9]+)$/\1/p' "$bridge_hold_output")"
case "$bridge_remote_hold_pid" in
  ''|*[!0-9]*) fail "could not identify the remote Docker bridge holder" ;;
esac

bridge_pid="$(container_exact_process_pid \
  "$primary_container" \
  "/usr/local/bin/node /usr/local/libexec/docker-bridge.js $docker_remote_socket_path")" \
  || fail "could not identify the bridge for SSH argv inspection"
docker exec "$primary_container" /bin/sh -c '
  set -eu
  bridge_pid=$1
  remote_socket=$2
  count=0
  ssh_pid=
  for process_dir in /proc/[0-9]*; do
    test -r "$process_dir/status" || continue
    parent="$(awk "\$1 == \"PPid:\" { print \$2 }" "$process_dir/status")"
    if test "$parent" = "$bridge_pid"; then
      first_argument="$(tr "\000" "\n" < "$process_dir/cmdline" 2>/dev/null | sed -n "1p" || true)"
      test "$first_argument" = /usr/bin/ssh || exit 1
      count=$((count + 1))
      ssh_pid=${process_dir##*/}
    fi
  done
  test "$count" -eq 1
  test "$(ps -o user= -p "$ssh_pid" | tr -d " ")" = codex
  actual="$(tr "\000" "\n" < "/proc/$ssh_pid/cmdline")"
  expected="$(printf "%s\n" \
    /usr/bin/ssh \
    -F \
    /etc/ssh/ssh_config \
    -T \
    -o \
    ClearAllForwardings=yes \
    -o \
    ControlMaster=no \
    -o \
    ControlPath=none \
    -- \
    docker-host \
    docker \
    "--host=unix://$remote_socket" \
    system \
    dial-stdio)"
  if test "$actual" != "$expected"; then
    printf "expected argv:\n%s\nactual argv:\n%s\n" "$expected" "$actual" >&2
    exit 1
  fi
' smoke-fixed-ssh-argv "$bridge_pid" "$docker_remote_socket_path" \
  || fail "the bridge SSH child does not use the exact fixed argv"

docker exec "$primary_container" kill -TERM "$bridge_remote_hold_pid" >/dev/null \
  || fail "could not terminate the remote Docker bridge holder"
wait "$bridge_hold_pid" >/dev/null 2>&1 || true
bridge_hold_pid=""
assert_log_excludes_key_material "$bridge_hold_output"
assert_log_excludes_key_material "$bridge_hold_error"
for attempt in $(seq 1 40); do
  if [ "$(bridge_ssh_child_count "$primary_container" "$docker_remote_socket_path")" = 0 ]; then
    break
  fi
  sleep 0.25
done
[ "$(bridge_ssh_child_count "$primary_container" "$docker_remote_socket_path")" = 0 ] \
  || fail "the bridge left an SSH transport child after its client disconnected"

offline_bundle="$(copy_docker_host_bundle_fixture offline)"
write_docker_host_fixture_field \
  "$offline_bundle" \
  ssh_host \
  "$offline_docker_host_hostname"
write_docker_host_fixture_field \
  "$offline_bundle" \
  ssh_port \
  "$offline_docker_host_port"
start_container \
  "$offline_container" \
  "$offline_home_volume" \
  "$offline_workspace_volume" \
  "$offline_bundle"
offline_known_hosts="$fixture_dir/known_hosts.offline"
offline_port="$(wait_for_ssh "$offline_container" "$offline_known_hosts")"
assert_container_state_contract "$offline_container"
assert_bridge_runtime_contract "$offline_container" "$docker_remote_socket_path"
assert_ssh_docker_environment \
  "$offline_known_hosts" \
  "$offline_port" \
  "$offline_docker_host_hostname" \
  "offline command SSH session"
if ssh_command "$offline_known_hosts" "$offline_port" "$fixture_dir/client_key" codex \
  'timeout --signal=KILL 15 docker info >/dev/null 2>&1'; then
  fail "Docker unexpectedly reached the deliberately offline SSH target"
fi
[ "$(docker inspect --format '{{.State.Running}}' "$offline_container")" = true ] \
  || fail "an offline Docker target stopped the devbox or blocked SSH readiness"
for attempt in $(seq 1 60); do
  if [ "$(bridge_ssh_child_count "$offline_container" "$docker_remote_socket_path")" = 0 ]; then
    break
  fi
  sleep 0.25
done
[ "$(bridge_ssh_child_count "$offline_container" "$docker_remote_socket_path")" = 0 ] \
  || fail "an offline Docker request left an SSH transport child behind"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "set -eu; test -w /home/codex; test -w /workspaces; printf '%s' '$state_marker' > /home/codex/.imageyard-smoke-state; printf '%s' '$state_marker' > /workspaces/.imageyard-smoke-state"

[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'codex --version')" = "codex-cli $expected_codex_version" ] \
  || fail "Codex version does not match $expected_codex_version"
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'codex app-server --help >/dev/null'
assert_ssh_app_server_protocol "$primary_known_hosts" "$primary_port"
# Reconnect to the same Home after a clean app-server exit.
assert_ssh_app_server_protocol "$primary_known_hosts" "$primary_port"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex '
  set -eu
  for required_command in node npm python3 pip3 git git-lfs gh ssh docker gcc make curl jq rg fd bwrap ip ss ping lsof nc strace sudo tini setpriv; do
    command -v "$required_command" >/dev/null
  done
  docker --version >/dev/null
  docker buildx version >/dev/null
  docker compose version >/dev/null
  python3 -m venv /tmp/imageyard-venv-smoke
  rm -rf /tmp/imageyard-venv-smoke
  for forbidden_command in dockerd containerd containerd-shim ctr podman nerdctl kubectl helm flux terraform tofu oras crane skopeo nvm pyenv; do
    if command -v "$forbidden_command" >/dev/null 2>&1; then
      exit 1
    fi
  done
'

docker exec "$primary_container" /bin/sh -c '
  set -eu
  package_version() {
    dpkg-query -W "$1" | awk "NR == 1 { print \$2 }"
  }
  test "$(package_version docker-ce-cli)" = "$1"
  test "$(package_version docker-buildx-plugin)" = "$2"
  test "$(package_version docker-compose-plugin)" = "$3"
  docker_cli_semver="$(docker --version | awk "NR == 1 { gsub(/,/, \"\", \$3); print \$3 }")"
  docker_buildx_semver="$(docker buildx version | awk "NR == 1 { sub(/^v/, \"\", \$2); print \$2 }")"
  docker_compose_semver="$(docker compose version --short | awk "NR == 1 { sub(/^v/, \"\", \$1); print \$1 }")"
  test "$docker_cli_semver" = "$4"
  test "$docker_buildx_semver" = "$5"
  test "$docker_compose_semver" = "$6"
  for forbidden_package in \
    docker-ce \
    docker-ce-rootless-extras \
    docker.io \
    docker-compose \
    containerd \
    containerd.io \
    podman; do
    if dpkg-query -s "$forbidden_package" 2>/dev/null \
      | grep -Fxq "Status: install ok installed"; then
      exit 1
    fi
  done
' sh \
  "$expected_docker_ce_cli_version" \
  "$expected_docker_buildx_version" \
  "$expected_docker_compose_version" \
  "$expected_docker_cli_semver" \
  "$expected_docker_buildx_semver" \
  "$expected_docker_compose_semver"

native_architecture="$(
  ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
    'dpkg --print-architecture'
)"
case "$native_architecture" in
  amd64|arm64) ;;
  *) fail "unsupported native package architecture: $native_architecture" ;;
esac
[ "$(docker image inspect --format '{{.Architecture}}' "$image")" = "$native_architecture" ] \
  || fail "image architecture does not match its installed package architecture"
engine_architecture="$(docker info --format '{{.Architecture}}')"
case "$engine_architecture" in
  x86_64) engine_architecture=amd64 ;;
  aarch64) engine_architecture=arm64 ;;
esac
[ "$engine_architecture" = "$native_architecture" ] \
  || fail "smoke test is not running on the image's native architecture"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex '
  set -eu
  ssh_listener_count="$(ss -H -lnt "sport = :2222" | wc -l)"
  docker_dns_listener_count="$(ss -H -lnt | awk '\''$4 ~ /^127\.0\.0\.11:/ { count++ } END { print count + 0 }'\'')"
  unexpected_listeners="$(ss -H -lnt | awk '\''$4 !~ /:2222$/ && $4 !~ /^127\.0\.0\.11:/ { print }'\'')"
  if test "$ssh_listener_count" -le 0 \
    || test "$docker_dns_listener_count" -gt 1 \
    || test -n "$unexpected_listeners"; then
    ss -H -lntp >&2
    exit 1
  fi
' || fail "container has an unexpected image-owned TCP listener"
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'if pgrep -x codex >/dev/null 2>&1; then exit 1; fi'

docker exec "$primary_container" /bin/sh -c '
  set -eu
  effective="$(/usr/sbin/sshd -T -f /run/codex-remote-devbox/sshd_config)"
  for expected_setting in \
    "port 2222" \
    "permitrootlogin no" \
    "passwordauthentication no" \
    "kbdinteractiveauthentication no" \
    "allowagentforwarding no" \
    "allowtcpforwarding local" \
    "allowstreamlocalforwarding no" \
    "x11forwarding no" \
    "permituserenvironment no" \
    "printmotd no" \
    "banner none" \
    "setenv DOCKER_HOST=$1" \
    "setenv TESTCONTAINERS_HOST_OVERRIDE=$2" \
    "setenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=$3"; do
    if ! printf "%s\n" "$effective" | grep -Fxq "$expected_setting"; then
      printf "missing effective sshd setting: %s\n" "$expected_setting" >&2
      printf "%s\n" "$effective" | grep -E "^(setenv|port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowagentforwarding|allowtcpforwarding|allowstreamlocalforwarding|x11forwarding|permituserenvironment|printmotd|banner) " >&2 || true
      exit 1
    fi
  done
  printf "%s\n" "$effective" | grep -Fq "127.0.0.1:*"
  printf "%s\n" "$effective" | grep -Fq "localhost:*"
' sh \
  "$docker_bridge_uri" \
  "$docker_host_hostname" \
  "$testcontainers_docker_socket_override" \
  || fail "effective runtime sshd configuration violates the image contract"

if ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/unknown_key" codex true \
  >/dev/null 2>&1; then
  fail "an unknown SSH key authenticated successfully"
fi
if ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" root true \
  >/dev/null 2>&1; then
  fail "root authenticated over SSH"
fi
password_probe_log="$fixture_dir/password-auth.log"
if ssh \
  -F /dev/null \
  -p "$primary_port" \
  -o ConnectTimeout=5 \
  -o NumberOfPasswordPrompts=0 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$primary_known_hosts" \
  -vv \
  codex@127.0.0.1 true </dev/null >/dev/null 2>"$password_probe_log"; then
  fail "password authentication succeeded"
fi
grep -E 'Authentications that can continue: publickey[[:space:]]*$' "$password_probe_log" >/dev/null \
  || fail "server did not advertise public-key-only authentication"
if grep -E 'Authentications that can continue:.*(password|keyboard-interactive)' "$password_probe_log" >/dev/null; then
  fail "server advertised password or keyboard-interactive authentication"
fi
assert_log_excludes_key_material "$password_probe_log"

ssh \
  -F /dev/null \
  -p "$primary_port" \
  -i "$fixture_dir/client_key" \
  -N \
  -R 0:127.0.0.1:22 \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o ExitOnForwardFailure=yes \
  -o IdentitiesOnly=yes \
  -o LogLevel=ERROR \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$primary_known_hosts" \
  codex@127.0.0.1 >/dev/null 2>&1 &
forward_pid=$!
forward_exited=false
for attempt in $(seq 1 20); do
  if ! kill -0 "$forward_pid" >/dev/null 2>&1; then
    forward_exited=true
    break
  fi
  sleep 0.25
done
if [ "$forward_exited" != true ]; then
  kill "$forward_pid" >/dev/null 2>&1 || true
  wait "$forward_pid" >/dev/null 2>&1 || true
  forward_pid=""
  fail "remote port forwarding remained active"
fi
if wait "$forward_pid"; then
  forward_pid=""
  fail "remote port forwarding succeeded"
fi
forward_pid=""

assert_state_excludes_secret_marker "$home_volume"
assert_state_excludes_secret_marker "$workspace_volume"
assert_no_probe_leftovers "$home_volume"
assert_no_probe_leftovers "$workspace_volume"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'exec sleep 300' \
  >"$fixture_dir/signal-session.stdout" 2>"$fixture_dir/signal-session.stderr" &
signal_session_pid=$!
signal_session_ready=false
for attempt in $(seq 1 20); do
  if ! kill -0 "$signal_session_pid" >/dev/null 2>&1; then
    break
  fi
  if docker exec "$primary_container" pgrep -u codex -x sleep >/dev/null 2>&1; then
    signal_session_ready=true
    break
  fi
  sleep 0.25
done
[ "$signal_session_ready" = true ] \
  || fail "could not establish an active SSH session for signal testing"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'exec node -e '"'"'const net=require("node:net");const target=process.env.DOCKER_HOST;const socket=net.createConnection({path:target.slice("unix://".length),allowHalfOpen:true},()=>{socket.write(Buffer.from("POST /hijack HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n"));process.stdout.write("signal-bridge-ready\n");});socket.on("data",()=>{});socket.on("error",()=>process.exit(1));setInterval(()=>{},1000);'"'"'' \
  >"$fixture_dir/signal-bridge.stdout" 2>"$fixture_dir/signal-bridge.stderr" &
signal_bridge_pid=$!
signal_bridge_ready=false
for attempt in $(seq 1 40); do
  if ! kill -0 "$signal_bridge_pid" >/dev/null 2>&1; then
    break
  fi
  if grep -Fq signal-bridge-ready "$fixture_dir/signal-bridge.stdout" 2>/dev/null \
    && [ "$(bridge_ssh_child_count "$primary_container" "$docker_remote_socket_path")" = 1 ]; then
    signal_bridge_ready=true
    break
  fi
  sleep 0.25
done
[ "$signal_bridge_ready" = true ] \
  || fail "could not establish an active bridge connection for signal testing"

docker stop --time 10 "$primary_container" >/dev/null
[ "$(docker inspect --format '{{.State.Running}}' "$primary_container")" = false ] \
  || fail "primary container remained running after docker stop"
[ "$(docker inspect --format '{{.State.OOMKilled}}' "$primary_container")" = false ] \
  || fail "primary container was OOM-killed during graceful stop"
primary_exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$primary_container")"
case "$primary_exit_code" in
  0|143) ;;
  *) fail "primary container did not stop gracefully (exit $primary_exit_code)" ;;
esac
signal_session_exited=false
for attempt in $(seq 1 20); do
  if ! kill -0 "$signal_session_pid" >/dev/null 2>&1; then
    signal_session_exited=true
    break
  fi
  sleep 0.25
done
[ "$signal_session_exited" = true ] \
  || fail "active SSH session survived the container SIGTERM"
wait "$signal_session_pid" >/dev/null 2>&1 || true
signal_session_pid=""

signal_bridge_exited=false
for attempt in $(seq 1 20); do
  if ! kill -0 "$signal_bridge_pid" >/dev/null 2>&1; then
    signal_bridge_exited=true
    break
  fi
  sleep 0.25
done
[ "$signal_bridge_exited" = true ] \
  || fail "active Docker bridge connection survived the container SIGTERM"
wait "$signal_bridge_pid" >/dev/null 2>&1 || true
signal_bridge_pid=""
assert_log_excludes_key_material "$fixture_dir/signal-bridge.stdout"
assert_log_excludes_key_material "$fixture_dir/signal-bridge.stderr"

start_container \
  "$restart_container" \
  "$home_volume" \
  "$workspace_volume" \
  "$fixture_dir/docker-host" \
  "$docker_backend_network"
restart_known_hosts="$fixture_dir/known_hosts.restart"
restart_port="$(wait_for_ssh "$restart_container" "$restart_known_hosts")"
restart_fingerprint="$(ssh-keygen -E sha256 -lf "$restart_known_hosts" | awk 'NR == 1 { print $2 }')"
[ "$restart_fingerprint" = "$primary_fingerprint" ] || fail "host fingerprint changed after restart"

assert_container_state_contract "$restart_container"
assert_bridge_runtime_contract "$restart_container" "$docker_remote_socket_path"
assert_volume_root_metadata "$home_volume" 1000:1000:700
assert_volume_root_metadata "$workspace_volume" 1000:1000:700
assert_seed_preserved "$home_volume" home 123:456 321:654 home-seed-content
assert_seed_preserved "$workspace_volume" workspaces 234:567 432:765 workspace-seed-content
assert_legacy_home_ssh_config_preserved "$home_volume"
assert_home_docker_config_enabled "$home_volume" absent
[ "$(record_home_docker_config_metadata "$home_volume")" = "$home_docker_config_metadata_before_restart" ] \
  || fail "idempotent restart rewrote the managed Home Docker configuration"
assert_no_probe_leftovers "$home_volume"
assert_no_probe_leftovers "$workspace_volume"
assert_volume_top_level_entries \
  "$home_volume" .codex .docker .imageyard-smoke-state .ssh seed-home
assert_volume_top_level_entries \
  "$workspace_volume" .imageyard-smoke-state seed-workspaces

[ "$(ssh_command "$restart_known_hosts" "$restart_port" "$fixture_dir/client_key" codex \
  'cat /home/codex/.imageyard-smoke-state')" = "$state_marker" ] \
  || fail "home state did not persist across replacement"
[ "$(ssh_command "$restart_known_hosts" "$restart_port" "$fixture_dir/client_key" codex \
  'cat /workspaces/.imageyard-smoke-state')" = "$state_marker" ] \
  || fail "workspace state did not persist across replacement"
assert_ssh_docker_environment \
  "$restart_known_hosts" \
  "$restart_port" \
  "$docker_host_hostname" \
  "replacement command SSH session"
assert_ssh_app_server_protocol "$restart_known_hosts" "$restart_port"
restart_daemon_id="$(
  ssh_command "$restart_known_hosts" "$restart_port" "$fixture_dir/client_key" codex \
    "docker info --format '{{.ID}}'"
)" || fail "replacement container could not use the local Docker bridge"
[ "$restart_daemon_id" = "$fake_docker_daemon_id" ] \
  || fail "replacement container reached an unexpected fake Docker daemon"

start_container \
  "$bridge_failure_container" \
  "$supervision_home_volume" \
  "$supervision_workspace_volume" \
  "$fixture_dir/docker-host" \
  "$docker_backend_network"
bridge_failure_known_hosts="$fixture_dir/known_hosts.bridge-failure"
bridge_failure_port="$(wait_for_ssh "$bridge_failure_container" "$bridge_failure_known_hosts")"
test -n "$bridge_failure_port" || fail "bridge-failure container did not publish SSH"
assert_bridge_runtime_contract "$bridge_failure_container" "$docker_remote_socket_path"
bridge_failure_pid="$(container_exact_process_pid \
  "$bridge_failure_container" \
  "/usr/local/bin/node /usr/local/libexec/docker-bridge.js $docker_remote_socket_path")" \
  || fail "could not identify the bridge child for failure supervision"
docker exec "$bridge_failure_container" kill -TERM "$bridge_failure_pid" >/dev/null \
  || fail "could not terminate the bridge child for failure supervision"
wait_for_runtime_failure \
  "$bridge_failure_container" \
  "$fixture_dir/bridge-failure.log" \
  'Docker bridge exited unexpectedly'

start_container \
  "$sshd_failure_container" \
  "$supervision_home_volume" \
  "$supervision_workspace_volume" \
  "$fixture_dir/docker-host" \
  "$docker_backend_network"
sshd_failure_known_hosts="$fixture_dir/known_hosts.sshd-failure"
sshd_failure_port="$(wait_for_ssh "$sshd_failure_container" "$sshd_failure_known_hosts")"
test -n "$sshd_failure_port" || fail "sshd-failure container did not publish SSH"
assert_bridge_runtime_contract "$sshd_failure_container" "$docker_remote_socket_path"
sshd_failure_supervisor_pid="$(container_exact_process_pid \
  "$sshd_failure_container" \
  "/usr/local/bin/node /usr/local/libexec/supervisor.js $docker_remote_socket_path")" \
  || fail "could not identify the supervisor for OpenSSH failure supervision"
sshd_failure_pid="$(container_supervised_sshd_pid \
  "$sshd_failure_container" \
  "$sshd_failure_supervisor_pid")" \
  || fail "could not identify the OpenSSH child for failure supervision"
docker exec "$sshd_failure_container" kill -TERM "$sshd_failure_pid" >/dev/null \
  || fail "could not terminate the OpenSSH child for failure supervision"
wait_for_runtime_failure \
  "$sshd_failure_container" \
  "$fixture_dir/sshd-failure.log" \
  'OpenSSH exited unexpectedly'

valid_access_mount="type=bind,src=$fixture_dir/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly"
valid_host_mount="type=bind,src=$fixture_dir/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly"

for required_name in ghcr_username ghcr_pat; do
  fixture_label="${required_name//_/-}"

  missing_bundle="$(copy_ghcr_bundle_fixture "missing-$fixture_label")"
  rm -f -- "$missing_bundle/$required_name"
  expect_ghcr_bundle_failure \
    "missing-$fixture_label" \
    "$missing_bundle" \
    'required GHCR Secret input is missing'

  empty_bundle="$(copy_ghcr_bundle_fixture "empty-$fixture_label")"
  chmod u+w "$empty_bundle/$required_name"
  : > "$empty_bundle/$required_name"
  if [ "$required_name" = ghcr_pat ]; then
    chmod 0400 "$empty_bundle/$required_name"
  else
    chmod 0444 "$empty_bundle/$required_name"
  fi
  expect_ghcr_bundle_failure \
    "empty-$fixture_label" \
    "$empty_bundle" \
    'required GHCR Secret input is empty'

  symlink_bundle="$(copy_ghcr_bundle_fixture "symlink-$fixture_label")"
  rm -f -- "$symlink_bundle/$required_name"
  symlink_target=ghcr_pat
  if [ "$required_name" = ghcr_pat ]; then
    symlink_target=ghcr_username
  fi
  ln -s "$symlink_target" "$symlink_bundle/$required_name"
  expect_ghcr_bundle_failure \
    "symlink-$fixture_label" \
    "$symlink_bundle" \
    'required GHCR Secret input is a symbolic link'

  directory_bundle="$(copy_ghcr_bundle_fixture "directory-$fixture_label")"
  rm -f -- "$directory_bundle/$required_name"
  mkdir "$directory_bundle/$required_name"
  expect_ghcr_bundle_failure \
    "directory-$fixture_label" \
    "$directory_bundle" \
    'required GHCR Secret input is not a regular file'

  wrong_mode_bundle="$(copy_ghcr_bundle_fixture "wrong-mode-$fixture_label")"
  if [ "$required_name" = ghcr_pat ]; then
    chmod 0444 "$wrong_mode_bundle/$required_name"
  else
    chmod 0400 "$wrong_mode_bundle/$required_name"
  fi
  expect_ghcr_bundle_failure \
    "wrong-mode-$fixture_label" \
    "$wrong_mode_bundle" \
    'source metadata is invalid'
done

invalid_ghcr_username_bundle="$(copy_ghcr_bundle_fixture invalid-username)"
write_ghcr_fixture_field "$invalid_ghcr_username_bundle" ghcr_username 'bad user'
expect_ghcr_bundle_failure \
  invalid-username \
  "$invalid_ghcr_username_bundle" \
  'GHCR username is invalid'

invalid_ghcr_pat_bundle="$(copy_ghcr_bundle_fixture invalid-pat)"
write_ghcr_fixture_field "$invalid_ghcr_pat_bundle" ghcr_pat 'ghp_invalid PAT value with spaces'
expect_ghcr_bundle_failure \
  invalid-pat \
  "$invalid_ghcr_pat_bundle" \
  'GHCR PAT is invalid'

high_bit_ghcr_username_bundle="$(copy_ghcr_bundle_fixture high-bit-username)"
chmod u+w "$high_bit_ghcr_username_bundle/ghcr_username"
printf '\301' > "$high_bit_ghcr_username_bundle/ghcr_username"
chmod 0444 "$high_bit_ghcr_username_bundle/ghcr_username"
expect_ghcr_bundle_failure \
  high-bit-username \
  "$high_bit_ghcr_username_bundle" \
  'GHCR username is invalid'

high_bit_ghcr_pat_bundle="$(copy_ghcr_bundle_fixture high-bit-pat)"
chmod u+w "$high_bit_ghcr_pat_bundle/ghcr_pat"
: > "$high_bit_ghcr_pat_bundle/ghcr_pat"
for high_bit_byte in $(seq 1 20); do
  printf '\341' >> "$high_bit_ghcr_pat_bundle/ghcr_pat"
done
chmod 0400 "$high_bit_ghcr_pat_bundle/ghcr_pat"
expect_ghcr_bundle_failure \
  high-bit-pat \
  "$high_bit_ghcr_pat_bundle" \
  'GHCR PAT is invalid'

expect_start_failure \
  "$malformed_docker_config_container" \
  "$fixture_dir/malformed-docker-config.log" \
  'GHCR Docker configuration failed' \
  --network none \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$malformed_config_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$malformed_config_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure \
  "$symlink_docker_config_container" \
  "$fixture_dir/symlink-docker-config.log" \
  'GHCR Docker configuration failed' \
  --network none \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$symlink_config_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$symlink_config_workspace_volume,dst=/workspaces,volume-nocopy"
for hostile_volume in \
  "$malformed_config_home_volume" \
  "$malformed_config_workspace_volume" \
  "$symlink_config_home_volume" \
  "$symlink_config_workspace_volume"; do
  assert_state_excludes_secret_marker "$hostile_volume"
  assert_no_probe_leftovers "$hostile_volume"
done

docker_host_required_names=(
  docker_host
  ssh_alias
  ssh_host
  ssh_port
  ssh_user
  ssh_client_ed25519_private_key
  ssh_client_ed25519_fingerprint
  ssh_host_ed25519_fingerprint
  ssh_known_hosts
)
for required_name in "${docker_host_required_names[@]}"; do
  fixture_label="${required_name//_/-}"

  missing_bundle="$(copy_docker_host_bundle_fixture "missing-$fixture_label")"
  rm -f -- "$missing_bundle/$required_name"
  expect_docker_host_bundle_failure \
    "missing-$fixture_label" \
    "$missing_bundle" \
    'required Docker host Secret'

  empty_bundle="$(copy_docker_host_bundle_fixture "empty-$fixture_label")"
  chmod u+w "$empty_bundle/$required_name"
  : > "$empty_bundle/$required_name"
  if [ "$required_name" = ssh_client_ed25519_private_key ]; then
    chmod 0400 "$empty_bundle/$required_name"
  else
    chmod 0444 "$empty_bundle/$required_name"
  fi
  expect_docker_host_bundle_failure \
    "empty-$fixture_label" \
    "$empty_bundle" \
    'required Docker host Secret'

  symlink_bundle="$(copy_docker_host_bundle_fixture "symlink-$fixture_label")"
  rm -f -- "$symlink_bundle/$required_name"
  symlink_target=ssh_alias
  if [ "$required_name" = ssh_alias ]; then
    symlink_target=docker_host
  fi
  ln -s "$symlink_target" "$symlink_bundle/$required_name"
  expect_docker_host_bundle_failure \
    "symlink-$fixture_label" \
    "$symlink_bundle" \
    'required Docker host Secret'

  directory_bundle="$(copy_docker_host_bundle_fixture "directory-$fixture_label")"
  rm -f -- "$directory_bundle/$required_name"
  mkdir "$directory_bundle/$required_name"
  expect_docker_host_bundle_failure \
    "directory-$fixture_label" \
    "$directory_bundle" \
    'required Docker host Secret'
done

invalid_alias_bundle="$(copy_docker_host_bundle_fixture invalid-alias)"
write_docker_host_fixture_field "$invalid_alias_bundle" ssh_alias other-alias
expect_docker_host_bundle_failure \
  invalid-alias \
  "$invalid_alias_bundle" \
  'Docker host SSH alias must be docker-host'

for invalid_host_case in 'bad host' '/absolute/path' '-leading-option'; do
  invalid_host_label="$(printf '%s' "$invalid_host_case" | cksum | awk '{ print $1 }')"
  invalid_host_bundle="$(copy_docker_host_bundle_fixture "invalid-host-$invalid_host_label")"
  write_docker_host_fixture_field "$invalid_host_bundle" ssh_host "$invalid_host_case"
  expect_docker_host_bundle_failure \
    "invalid-host-$invalid_host_label" \
    "$invalid_host_bundle" \
    'Docker host SSH hostname is invalid'
done

for invalid_port_case in 0 65536 22x; do
  invalid_port_bundle="$(copy_docker_host_bundle_fixture "invalid-port-$invalid_port_case")"
  write_docker_host_fixture_field "$invalid_port_bundle" ssh_port "$invalid_port_case"
  expect_docker_host_bundle_failure \
    "invalid-port-$invalid_port_case" \
    "$invalid_port_bundle" \
    'Docker host SSH port is invalid'
done

for invalid_user_case in 'bad user' '-leading-option' 'user/name'; do
  invalid_user_label="$(printf '%s' "$invalid_user_case" | cksum | awk '{ print $1 }')"
  invalid_user_bundle="$(copy_docker_host_bundle_fixture "invalid-user-$invalid_user_label")"
  write_docker_host_fixture_field "$invalid_user_bundle" ssh_user "$invalid_user_case"
  expect_docker_host_bundle_failure \
    "invalid-user-$invalid_user_label" \
    "$invalid_user_bundle" \
    'Docker host SSH user is invalid'
done

invalid_uri_scheme_bundle="$(copy_docker_host_bundle_fixture invalid-uri-scheme)"
write_docker_host_fixture_field \
  "$invalid_uri_scheme_bundle" \
  docker_host \
  'tcp://docker-host:2375'
expect_docker_host_bundle_failure \
  invalid-uri-scheme \
  "$invalid_uri_scheme_bundle" \
  'Docker host URI is invalid'

invalid_uri_alias_bundle="$(copy_docker_host_bundle_fixture invalid-uri-alias)"
write_docker_host_fixture_field \
  "$invalid_uri_alias_bundle" \
  docker_host \
  'ssh://other-alias/Users/imageyard/.docker/run/docker.sock'
expect_docker_host_bundle_failure \
  invalid-uri-alias \
  "$invalid_uri_alias_bundle" \
  'Docker host URI is invalid'

invalid_uri_path_bundle="$(copy_docker_host_bundle_fixture invalid-uri-path)"
write_docker_host_fixture_field \
  "$invalid_uri_path_bundle" \
  docker_host \
  'ssh://docker-host'
expect_docker_host_bundle_failure \
  invalid-uri-path \
  "$invalid_uri_path_bundle" \
  'Docker host URI is invalid'

invalid_client_key_bundle="$(copy_docker_host_bundle_fixture invalid-client-key)"
write_docker_host_fixture_field \
  "$invalid_client_key_bundle" \
  ssh_client_ed25519_private_key \
  "not-a-private-key-$docker_secret_marker"
expect_docker_host_bundle_failure \
  invalid-client-key \
  "$invalid_client_key_bundle" \
  'Docker host client key is not a valid Ed25519 private key'

rsa_client_key_bundle="$(copy_docker_host_bundle_fixture rsa-client-key)"
copy_docker_host_fixture_private_key \
  "$rsa_client_key_bundle" \
  "$fixture_dir/rsa_docker_client_key"
expect_docker_host_bundle_failure \
  rsa-client-key \
  "$rsa_client_key_bundle" \
  'Docker host client key is not a valid Ed25519 private key'

client_fingerprint_mismatch_bundle="$(copy_docker_host_bundle_fixture client-fingerprint-mismatch)"
write_docker_host_fixture_field \
  "$client_fingerprint_mismatch_bundle" \
  ssh_client_ed25519_fingerprint \
  "$alternate_docker_client_fingerprint"
expect_docker_host_bundle_failure \
  client-fingerprint-mismatch \
  "$client_fingerprint_mismatch_bundle" \
  'Docker host client key fingerprint does not match'

invalid_client_fingerprint_bundle="$(copy_docker_host_bundle_fixture invalid-client-fingerprint)"
write_docker_host_fixture_field \
  "$invalid_client_fingerprint_bundle" \
  ssh_client_ed25519_fingerprint \
  'SHA256:not-valid!'
expect_docker_host_bundle_failure \
  invalid-client-fingerprint \
  "$invalid_client_fingerprint_bundle" \
  'Docker host client key fingerprint is invalid'

invalid_host_fingerprint_bundle="$(copy_docker_host_bundle_fixture invalid-host-fingerprint)"
write_docker_host_fixture_field \
  "$invalid_host_fingerprint_bundle" \
  ssh_host_ed25519_fingerprint \
  'SHA256:not-valid!'
expect_docker_host_bundle_failure \
  invalid-host-fingerprint \
  "$invalid_host_fingerprint_bundle" \
  'Docker host key fingerprint is invalid'

known_hosts_endpoint_bundle="$(copy_docker_host_bundle_fixture known-hosts-endpoint)"
write_docker_host_fixture_field \
  "$known_hosts_endpoint_bundle" \
  ssh_known_hosts \
  "other-alias $docker_remote_host_public_key_material"
expect_docker_host_bundle_failure \
  known-hosts-endpoint \
  "$known_hosts_endpoint_bundle" \
  'Docker host known_hosts must contain exactly one matching Ed25519 entry'

known_hosts_extra_bundle="$(copy_docker_host_bundle_fixture known-hosts-extra)"
write_docker_host_fixture_field \
  "$known_hosts_extra_bundle" \
  ssh_known_hosts \
  "$docker_host_alias $docker_remote_host_public_key_material
other-alias $docker_remote_host_public_key_material"
expect_docker_host_bundle_failure \
  known-hosts-extra \
  "$known_hosts_extra_bundle" \
  'Docker host known_hosts must contain exactly one matching Ed25519 entry'

known_hosts_rsa_bundle="$(copy_docker_host_bundle_fixture known-hosts-rsa)"
write_docker_host_fixture_field \
  "$known_hosts_rsa_bundle" \
  ssh_known_hosts \
  "$docker_host_alias ssh-rsa $rsa_docker_remote_host_key_blob"
expect_docker_host_bundle_failure \
  known-hosts-rsa \
  "$known_hosts_rsa_bundle" \
  'Docker host known_hosts must contain exactly one matching Ed25519 entry'

known_hosts_key_mismatch_bundle="$(copy_docker_host_bundle_fixture known-hosts-key-mismatch)"
write_docker_host_fixture_field \
  "$known_hosts_key_mismatch_bundle" \
  ssh_known_hosts \
  "$docker_host_alias ssh-ed25519 $alternate_docker_remote_host_key_blob"
expect_docker_host_bundle_failure \
  known-hosts-key-mismatch \
  "$known_hosts_key_mismatch_bundle" \
  'Docker host known_hosts fingerprint does not match'

host_fingerprint_mismatch_bundle="$(copy_docker_host_bundle_fixture host-fingerprint-mismatch)"
write_docker_host_fixture_field \
  "$host_fingerprint_mismatch_bundle" \
  ssh_host_ed25519_fingerprint \
  "$alternate_docker_remote_host_fingerprint"
expect_docker_host_bundle_failure \
  host-fingerprint-mismatch \
  "$host_fingerprint_mismatch_bundle" \
  'Docker host known_hosts fingerprint does not match'

assert_volume_root_metadata "$support_home_volume" 0:0:755
assert_volume_root_metadata "$support_workspace_volume" 0:0:755

expect_start_failure "$missing_home_container" "$fixture_dir/missing-home.log" \
  'required state root is not an exact mountpoint: /home/codex' \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$support_workspace_volume" 0:0:755
expect_start_failure "$missing_workspace_container" "$fixture_dir/missing-workspace.log" \
  'required state root is not an exact mountpoint: /workspaces' \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy"
assert_volume_root_metadata "$support_home_volume" 0:0:755

expect_state_type_failure "$missing_path_home_container" "$fixture_dir/missing-path-home.log" /home/codex missing \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$support_workspace_volume" 0:0:755
expect_start_failure "$parent_home_container" "$fixture_dir/parent-home.log" \
  'required state root is not an exact mountpoint: /home/codex' \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$parent_home_volume,dst=/home,volume-nocopy" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$support_workspace_volume" 0:0:755

expect_state_type_failure "$file_home_container" "$fixture_dir/file-home.log" /home/codex file \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$support_workspace_volume" 0:0:755
expect_state_type_failure "$file_workspace_container" "$fixture_dir/file-workspace.log" /workspaces file \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy"
assert_volume_root_metadata "$support_home_volume" 0:0:755
expect_state_type_failure "$symlink_home_container" "$fixture_dir/symlink-home.log" /home/codex symlink \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$support_workspace_volume" 0:0:755
expect_state_type_failure "$symlink_workspace_container" "$fixture_dir/symlink-workspace.log" /workspaces symlink \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy"
assert_volume_root_metadata "$support_home_volume" 0:0:755

expect_start_failure "$readonly_home_container" "$fixture_dir/readonly-home.log" \
  'codex cannot create files in state root: /home/codex' \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$readonly_home_volume,dst=/home/codex,volume-nocopy,readonly" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure "$readonly_workspace_container" "$fixture_dir/readonly-workspace.log" \
  'codex cannot create files in state root: /workspaces' \
  --mount "$valid_access_mount" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$readonly_workspace_volume,dst=/workspaces,volume-nocopy,readonly"

expect_start_failure "$missing_access_container" "$fixture_dir/missing-access.log" \
  'required runtime key file is missing: /run/secrets/ssh-access/authorized_keys' \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure "$missing_host_container" "$fixture_dir/missing-host.log" \
  'required runtime key file is missing: /run/secrets/ssh-host/ssh_host_ed25519_key' \
  --mount "$valid_access_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure "$empty_access_container" "$fixture_dir/empty-access.log" \
  'required runtime key file is empty: /run/secrets/ssh-access/authorized_keys' \
  --mount "type=bind,src=$fixture_dir/empty_authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure "$invalid_access_container" "$fixture_dir/invalid-access.log" \
  'authorized_keys must contain only bare OpenSSH public keys' \
  --mount "type=bind,src=$fixture_dir/invalid_authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$invalid_secret_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$invalid_secret_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$invalid_secret_home_volume" 0:0:755
assert_volume_root_metadata "$invalid_secret_workspace_volume" 0:0:755
assert_seed_preserved "$invalid_secret_home_volume" invalid-home 345:678 543:876 invalid-home-seed
assert_seed_preserved "$invalid_secret_workspace_volume" invalid-workspaces 456:789 654:987 invalid-workspace-seed
assert_no_probe_leftovers "$invalid_secret_home_volume"
assert_no_probe_leftovers "$invalid_secret_workspace_volume"

expect_start_failure "$mixed_invalid_access_container" "$fixture_dir/mixed-invalid-access.log" \
  'authorized_keys contains invalid public key data' \
  --mount "type=bind,src=$fixture_dir/mixed_invalid_authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure "$private_access_container" "$fixture_dir/private-access.log" \
  'authorized_keys must contain only bare OpenSSH public keys' \
  --mount "type=bind,src=$fixture_dir/client_key,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
  --mount "$valid_host_mount" \
  --mount "type=volume,src=$support_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$support_workspace_volume,dst=/workspaces,volume-nocopy"
expect_start_failure "$invalid_host_container" "$fixture_dir/invalid-host.log" \
  'host key is not a valid Ed25519 private key' \
  --mount "$valid_access_mount" \
  --mount "type=bind,src=$fixture_dir/invalid_host_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
  --mount "type=volume,src=$invalid_secret_home_volume,dst=/home/codex,volume-nocopy" \
  --mount "type=volume,src=$invalid_secret_workspace_volume,dst=/workspaces,volume-nocopy"
assert_volume_root_metadata "$invalid_secret_home_volume" 0:0:755
assert_volume_root_metadata "$invalid_secret_workspace_volume" 0:0:755
assert_seed_preserved "$invalid_secret_home_volume" invalid-home 345:678 543:876 invalid-home-seed
assert_seed_preserved "$invalid_secret_workspace_volume" invalid-workspaces 456:789 654:987 invalid-workspace-seed
assert_no_probe_leftovers "$invalid_secret_home_volume"
assert_no_probe_leftovers "$invalid_secret_workspace_volume"

for observed_container in \
  "$primary_container" \
  "$restart_container" \
  "$offline_container" \
  "$docker_backend_container"; do
  observed_log="$fixture_dir/${observed_container}.log"
  docker logs "$observed_container" >"$observed_log" 2>&1 \
    || fail "could not retrieve logs for $observed_container"
  assert_log_excludes_key_material "$observed_log"
done

for volume_name in "${cleanup_volumes[@]}"; do
  assert_state_excludes_secret_marker "$volume_name"
  assert_no_probe_leftovers "$volume_name"
done
record_secret_sources > "$fixture_dir/secret-sources.after"
cmp -s "$fixture_dir/secret-sources.before" "$fixture_dir/secret-sources.after" \
  || fail "runtime secret source files changed during container startup"

printf 'Codex remote devbox smoke tests passed for %s\n' "$image"
