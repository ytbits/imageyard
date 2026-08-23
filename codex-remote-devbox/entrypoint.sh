#!/bin/sh
set -eu

authorized_keys_source=/run/secrets/ssh-access/authorized_keys
host_key_source=/run/secrets/ssh-host/ssh_host_ed25519_key
runtime_dir=/run/codex-remote-devbox
authorized_keys_runtime="$runtime_dir/authorized_keys"
host_key_runtime="$runtime_dir/ssh_host_ed25519_key"
authorized_keys_validation="$runtime_dir/authorized_keys.validation"
authorized_key_validation="$runtime_dir/authorized_key.validation"
mountinfo=/proc/self/mountinfo
state_probe=

cleanup_state_probe() {
  if [ -n "$state_probe" ]; then
    rm -f -- "$state_probe" >/dev/null 2>&1 || :
    state_probe=
  fi
}

fail() {
  cleanup_state_probe
  printf '%s\n' "codex-remote-devbox: $*" >&2
  exit 1
}

handle_signal() {
  signal_status=$1
  trap - HUP INT TERM
  cleanup_state_probe
  exit "$signal_status"
}

is_exact_mountpoint() {
  awk -v expected="$1" '
    $5 == expected { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$mountinfo"
}

validate_state_root() {
  state_root=$1

  [ ! -L "$state_root" ] \
    || fail "required state root is a symbolic link: $state_root"
  [ -e "$state_root" ] || fail "required state root is missing: $state_root"
  [ -d "$state_root" ] \
    || fail "required state root is not a directory: $state_root"
  is_exact_mountpoint "$state_root" \
    || fail "required state root is not an exact mountpoint: $state_root"
}

bootstrap_state_root() {
  state_root=$1

  state_owner="$(stat -c '%u:%g' -- "$state_root" 2>/dev/null)" \
    || fail "could not inspect state root ownership: $state_root"
  if [ "$state_owner" != 1000:1000 ]; then
    chown 1000:1000 -- "$state_root" \
      || fail "could not set state root ownership: $state_root"
  fi

  state_mode="$(stat -c '%a' -- "$state_root" 2>/dev/null)" \
    || fail "could not inspect state root mode: $state_root"
  if [ "$state_mode" != 700 ]; then
    chmod 0700 -- "$state_root" \
      || fail "could not set state root mode: $state_root"
  fi

  [ ! -L "$state_root" ] \
    || fail "state root became a symbolic link: $state_root"
  [ -d "$state_root" ] \
    || fail "state root is no longer a directory: $state_root"
  is_exact_mountpoint "$state_root" \
    || fail "state root is no longer an exact mountpoint: $state_root"
  [ "$(stat -c '%u:%g:%a' -- "$state_root" 2>/dev/null)" = 1000:1000:700 ] \
    || fail "state root metadata verification failed: $state_root"

  probe_token=
  IFS= read -r probe_token < /proc/sys/kernel/random/uuid \
    || fail "could not allocate state root write probe: $state_root"
  case "$probe_token" in
    ''|*[!0-9a-f-]*)
      fail "could not allocate state root write probe: $state_root"
      ;;
  esac
  probe_candidate="$state_root/.codex-remote-devbox-write-test.$probe_token"
  [ ! -e "$probe_candidate" ] && [ ! -L "$probe_candidate" ] \
    || fail "could not allocate state root write probe: $state_root"
  state_probe=$probe_candidate
  sudo -n -u codex -- /bin/sh -c \
    'set -C; umask 077; : > "$1"' state-write-probe "$state_probe" \
    2>/dev/null || fail "codex cannot create files in state root: $state_root"
  sudo -n -u codex -- rm -f -- "$state_probe" >/dev/null 2>&1 \
    || fail "codex cannot remove files from state root: $state_root"
  state_probe=
}

trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

[ "$(id -u)" = 0 ] || fail "entrypoint must run as root"

codex_uid="$(id -u codex 2>/dev/null)" || fail "codex account is unavailable"
[ "$codex_uid" = 1000 ] || fail "codex UID is not 1000"
codex_gid="$(id -g codex 2>/dev/null)" || fail "codex account is unavailable"
[ "$codex_gid" = 1000 ] || fail "codex GID is not 1000"
codex_passwd="$(getent passwd codex 2>/dev/null)" \
  || fail "codex account is unavailable"
[ "$(printf '%s\n' "$codex_passwd" | cut -d: -f7)" = /bin/bash ] \
  || fail "codex login shell is not /bin/bash"

[ -r "$mountinfo" ] || fail "mount table is unavailable"
for state_root in /home/codex /workspaces; do
  validate_state_root "$state_root"
done

for required_file in "$authorized_keys_source" "$host_key_source"; do
  [ -f "$required_file" ] || fail "required runtime key file is missing: $required_file"
  [ -r "$required_file" ] || fail "required runtime key file is unreadable: $required_file"
  [ -s "$required_file" ] || fail "required runtime key file is empty: $required_file"
done

install -d -o root -g root -m 0755 /run/sshd
install -d -o root -g root -m 0755 "$runtime_dir"
install -o root -g root -m 0644 "$authorized_keys_source" "$authorized_keys_runtime"
install -o root -g root -m 0600 "$host_key_source" "$host_key_runtime"
install -o root -g root -m 0600 /dev/null "$authorized_keys_validation"
install -o root -g root -m 0600 /dev/null "$authorized_key_validation"

if ! awk '
  /^[[:space:]]*($|#)/ { next }
  $1 ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ &&
    $2 ~ /^[A-Za-z0-9+\/=]+$/ {
      print $1 " " $2
      valid_keys++
      next
    }
  { exit 1 }
  END { if (valid_keys == 0) exit 1 }
' "$authorized_keys_runtime" > "$authorized_keys_validation"; then
  fail "authorized_keys must contain only bare OpenSSH public keys"
fi

while IFS= read -r authorized_key; do
  printf '%s\n' "$authorized_key" > "$authorized_key_validation"
  ssh-keygen -l -f "$authorized_key_validation" >/dev/null 2>&1 \
    || fail "authorized_keys contains invalid public key data"
done < "$authorized_keys_validation"
rm -f "$authorized_keys_validation" "$authorized_key_validation"

host_key_type="$(ssh-keygen -y -f "$host_key_runtime" 2>/dev/null | awk 'NR == 1 { print $1 }')"
[ "$host_key_type" = ssh-ed25519 ] \
  || fail "host key is not a valid Ed25519 private key"

/usr/sbin/sshd -t -f /etc/ssh/sshd_config \
  || fail "OpenSSH configuration validation failed"

for state_root in /home/codex /workspaces; do
  bootstrap_state_root "$state_root"
done

trap - HUP INT TERM
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
