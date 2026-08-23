#!/usr/bin/env bash
set -euo pipefail

image="${1:-ghcr.io/ytbits/codex-remote-devbox:codex-0.149.0-r2}"
expected_codex_version="${EXPECTED_CODEX_VERSION:-0.149.0}"
secret_marker="IMAGEYARD_SMOKE_SECRET_DO_NOT_BAKE_7e4fdd65"
state_marker="IMAGEYARD_SMOKE_STATE_PERSISTS_b91c6c82"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-devbox-smoke.XXXXXX")"
fixture_token="${fixture_dir##*.}"
name_prefix="codex-remote-devbox-smoke-$$-${fixture_token}"

primary_container="${name_prefix}-primary"
restart_container="${name_prefix}-restart"
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

home_volume="${name_prefix}-home"
workspace_volume="${name_prefix}-workspaces"
support_home_volume="${name_prefix}-support-home"
support_workspace_volume="${name_prefix}-support-workspaces"
readonly_home_volume="${name_prefix}-readonly-home"
readonly_workspace_volume="${name_prefix}-readonly-workspaces"
invalid_secret_home_volume="${name_prefix}-invalid-secret-home"
invalid_secret_workspace_volume="${name_prefix}-invalid-secret-workspaces"
parent_home_volume="${name_prefix}-parent-home"

declare -a cleanup_containers=(
  "$primary_container"
  "$restart_container"
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
)
declare -a cleanup_volumes=()
declare -a secret_source_files=()
forward_pid=""
signal_session_pid=""

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

  docker rm -f "${cleanup_containers[@]}" >/dev/null 2>&1 || true
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

for command_name in cksum cmp docker ssh ssh-keygen ssh-keyscan stat; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required host command is unavailable: $command_name"
done

docker image inspect "$image" >/dev/null 2>&1 \
  || fail "image is not available locally: $image"

mkdir -p "$fixture_dir/access" "$fixture_dir/host"

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

secret_source_files=(
  "$fixture_dir/access/authorized_keys"
  "$fixture_dir/host/ssh_host_ed25519_key"
  "$fixture_dir/empty_authorized_keys"
  "$fixture_dir/invalid_authorized_keys"
  "$fixture_dir/mixed_invalid_authorized_keys"
  "$fixture_dir/client_key"
  "$fixture_dir/invalid_host_key"
)
authorized_key_material="$(awk 'NR == 1 { print $1 " " $2 }' "$fixture_dir/access/authorized_keys")"
host_public_key_material="$(ssh-keygen -y -f "$fixture_dir/host/ssh_host_ed25519_key")"
[ -n "$authorized_key_material" ] || fail "could not derive the authorized public key fixture"
[ -n "$host_public_key_material" ] || fail "could not derive the host public key fixture"

record_secret_sources() {
  local source_file
  local source_metadata

  for source_file in "${secret_source_files[@]}"; do
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
    for forbidden_material in "$1" "$2" "$3" "-----BEGIN OPENSSH PRIVATE KEY-----"; do
      grep_status=0
      grep -r -F -q -- "$forbidden_material" /state 2>/dev/null || grep_status=$?
      case "$grep_status" in
        0) exit 1 ;;
        1) ;;
        *) exit 2 ;;
      esac
    done
  ' "$secret_marker" "$authorized_key_material" "$host_public_key_material"; then
    fail "state volume $volume_name contains runtime SSH key material"
  fi
}

for volume_name in \
  "$home_volume" \
  "$workspace_volume" \
  "$support_home_volume" \
  "$support_workspace_volume" \
  "$readonly_home_volume" \
  "$readonly_workspace_volume" \
  "$invalid_secret_home_volume" \
  "$invalid_secret_workspace_volume" \
  "$parent_home_volume"; do
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
seed_state_volume "$invalid_secret_home_volume" invalid-home 345:678 543:876 invalid-home-seed
seed_state_volume "$invalid_secret_workspace_volume" invalid-workspaces 456:789 654:987 invalid-workspace-seed

start_container() {
  local container_name="$1"
  local container_home_volume="$2"
  local container_workspace_volume="$3"

  docker run --detach \
    --name "$container_name" \
    --publish 127.0.0.1::2222 \
    --mount "type=bind,src=$fixture_dir/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly" \
    --mount "type=bind,src=$fixture_dir/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly" \
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

assert_log_excludes_key_material() {
  local log_file="$1"
  local forbidden_material
  local grep_status
  local source_file

  for forbidden_material in \
    "$secret_marker" \
    "$authorized_key_material" \
    "$host_public_key_material"; do
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
  shift 3

  if ! docker run --detach --name "$container_name" "$@" "$image" \
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

  if ! docker run --detach \
    --name "$container_name" \
    "$@" \
    --entrypoint /bin/sh \
    "$image" \
    -c "$wrapper" smoke-state "$state_root" \
    > /dev/null 2>"$log_file"; then
    fail "Docker could not create $container_name"
  fi

  wait_for_start_failure "$container_name" "$log_file" "$expected_log"
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
if grep -Fq "$secret_marker" "$fixture_dir/image-inspect.json"; then
  fail "image metadata contains the smoke-test secret marker"
fi
docker history --no-trunc "$image" > "$fixture_dir/image-history.txt"
if grep -Fq "$secret_marker" "$fixture_dir/image-history.txt"; then
  fail "image history contains the smoke-test secret marker"
fi

docker create --name "$audit_container" --entrypoint /bin/sh "$image" -c true >/dev/null
docker export "$audit_container" > "$fixture_dir/rootfs.tar"
tar -tf "$fixture_dir/rootfs.tar" > "$fixture_dir/rootfs.list"
if grep -E '(^|/)ssh_host_[^/]*_key$|(^|/)authorized_keys$' "$fixture_dir/rootfs.list" >/dev/null; then
  fail "image filesystem contains an SSH host or authorized key"
fi
if ! docker run --rm \
  --name "$filesystem_audit_container" \
  --entrypoint /bin/sh \
  "$image" \
  -c '
    set -eu
    test ! -e /home/codex/.codex/auth.json
    test ! -e /home/codex/.config/gh/hosts.yml
    if find /etc/ssh /home/codex /root -type f -exec grep -I -l -E "^-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----" {} + 2>/dev/null | grep -q .; then
      exit 1
    fi
    if grep -R -F -l "$1" /etc /home /root /usr/local 2>/dev/null | grep -q .; then
      exit 1
    fi
  ' sh "$secret_marker"; then
  fail "image filesystem contains credential material or the smoke-test marker"
fi

start_container "$primary_container" "$home_volume" "$workspace_volume"
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
expected_mounts="$(printf '%s\n' /home/codex /run/secrets/ssh-access/authorized_keys /run/secrets/ssh-host/ssh_host_ed25519_key /workspaces | sort)"
[ "$actual_mounts" = "$expected_mounts" ] \
  || fail "container uses unexpected mounts: $(printf '%s' "$actual_mounts" | paste -sd, -)"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/codex"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$primary_container")" = "volume:$home_volume" ] \
  || fail "home state is not backed by the expected named volume"
[ "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/workspaces"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$primary_container")" = "volume:$workspace_volume" ] \
  || fail "workspace state is not backed by the expected named volume"

assert_container_state_contract "$primary_container"
assert_volume_root_metadata "$home_volume" 1000:1000:700
assert_volume_root_metadata "$workspace_volume" 1000:1000:700
assert_seed_preserved "$home_volume" home 123:456 321:654 home-seed-content
assert_seed_preserved "$workspace_volume" workspaces 234:567 432:765 workspace-seed-content
assert_no_probe_leftovers "$home_volume"
assert_no_probe_leftovers "$workspace_volume"
assert_volume_top_level_entries "$home_volume" seed-home
assert_volume_top_level_entries "$workspace_volume" seed-workspaces

docker exec "$primary_container" /bin/sh -c '
  set -eu
  test "$(ps -o comm= -p 1 | tr -d " ")" = tini
  test "$(tr "\000" " " < /proc/1/cmdline)" = "/usr/bin/tini -g -- /usr/local/bin/codex-remote-devbox-entrypoint "
  sshd_pid="$(pgrep -o -x sshd)"
  test -n "$sshd_pid"
  test "$(ps -o user= -p "$sshd_pid" | tr -d " ")" = root
  test ! -S /var/run/docker.sock
'

clean_stdout="$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "printf '%s' codex-smoke-output" 2>"$fixture_dir/ssh.stderr")"
[ "$clean_stdout" = codex-smoke-output ] || fail "noninteractive SSH stdout contains a banner or MOTD"

[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'id -u')" = 1000 ] \
  || fail "SSH session UID is not 1000"
[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'id -g')" = 1000 ] \
  || fail "SSH session GID is not 1000"
[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "getent passwd codex | cut -d: -f7")" = /bin/bash ] \
  || fail "codex login shell is not Bash"
[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'sudo -n id -u')" = 0 ] \
  || fail "passwordless sudo is unavailable"

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  "set -eu; test -w /home/codex; test -w /workspaces; printf '%s' '$state_marker' > /home/codex/.imageyard-smoke-state; printf '%s' '$state_marker' > /workspaces/.imageyard-smoke-state"

[ "$(ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex 'codex --version')" = "codex-cli $expected_codex_version" ] \
  || fail "Codex version does not match $expected_codex_version"
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'codex app-server --help >/dev/null'

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex '
  set -eu
  for required_command in node npm python3 pip3 git git-lfs gh ssh gcc make curl jq rg fd bwrap ip ss ping lsof nc strace sudo tini; do
    command -v "$required_command" >/dev/null
  done
  python3 -m venv /tmp/imageyard-venv-smoke
  rm -rf /tmp/imageyard-venv-smoke
  for forbidden_command in docker dockerd podman nerdctl kubectl helm flux terraform tofu oras crane skopeo nvm pyenv; do
    if command -v "$forbidden_command" >/dev/null 2>&1; then
      exit 1
    fi
  done
'

ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex '
  set -eu
  listener_count="$(ss -H -lnt | wc -l)"
  ssh_listener_count="$(ss -H -lnt "sport = :2222" | wc -l)"
  test "$listener_count" -gt 0
  test "$listener_count" -eq "$ssh_listener_count"
' || fail "container listens on a port other than TCP 2222"
ssh_command "$primary_known_hosts" "$primary_port" "$fixture_dir/client_key" codex \
  'if pgrep -x codex >/dev/null 2>&1; then exit 1; fi'

effective_sshd="$fixture_dir/sshd.effective"
docker exec "$primary_container" /usr/sbin/sshd -T -f /etc/ssh/sshd_config > "$effective_sshd"
for expected_setting in \
  'port 2222' \
  'permitrootlogin no' \
  'passwordauthentication no' \
  'kbdinteractiveauthentication no' \
  'allowagentforwarding no' \
  'allowtcpforwarding local' \
  'allowstreamlocalforwarding no' \
  'x11forwarding no' \
  'permituserenvironment no' \
  'printmotd no' \
  'banner none'; do
  grep -Fxq "$expected_setting" "$effective_sshd" \
    || fail "effective sshd configuration is missing: $expected_setting"
done
grep -Fq '127.0.0.1:*' "$effective_sshd" || fail "local forwarding is not restricted to loopback"
grep -Fq 'localhost:*' "$effective_sshd" || fail "localhost forwarding is not permitted"

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

start_container "$restart_container" "$home_volume" "$workspace_volume"
restart_known_hosts="$fixture_dir/known_hosts.restart"
restart_port="$(wait_for_ssh "$restart_container" "$restart_known_hosts")"
restart_fingerprint="$(ssh-keygen -E sha256 -lf "$restart_known_hosts" | awk 'NR == 1 { print $2 }')"
[ "$restart_fingerprint" = "$primary_fingerprint" ] || fail "host fingerprint changed after restart"

assert_container_state_contract "$restart_container"
assert_volume_root_metadata "$home_volume" 1000:1000:700
assert_volume_root_metadata "$workspace_volume" 1000:1000:700
assert_seed_preserved "$home_volume" home 123:456 321:654 home-seed-content
assert_seed_preserved "$workspace_volume" workspaces 234:567 432:765 workspace-seed-content
assert_no_probe_leftovers "$home_volume"
assert_no_probe_leftovers "$workspace_volume"
assert_volume_top_level_entries \
  "$home_volume" .codex .imageyard-smoke-state seed-home
assert_volume_top_level_entries \
  "$workspace_volume" .imageyard-smoke-state seed-workspaces

[ "$(ssh_command "$restart_known_hosts" "$restart_port" "$fixture_dir/client_key" codex \
  'cat /home/codex/.imageyard-smoke-state')" = "$state_marker" ] \
  || fail "home state did not persist across replacement"
[ "$(ssh_command "$restart_known_hosts" "$restart_port" "$fixture_dir/client_key" codex \
  'cat /workspaces/.imageyard-smoke-state')" = "$state_marker" ] \
  || fail "workspace state did not persist across replacement"

valid_access_mount="type=bind,src=$fixture_dir/access/authorized_keys,dst=/run/secrets/ssh-access/authorized_keys,readonly"
valid_host_mount="type=bind,src=$fixture_dir/host/ssh_host_ed25519_key,dst=/run/secrets/ssh-host/ssh_host_ed25519_key,readonly"

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

for observed_container in "$primary_container" "$restart_container"; do
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
