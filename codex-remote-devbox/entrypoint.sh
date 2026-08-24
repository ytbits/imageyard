#!/bin/sh
set -eu

unset DOCKER_HOST DOCKER_CONTEXT || :

authorized_keys_source=/run/secrets/ssh-access/authorized_keys
host_key_source=/run/secrets/ssh-host/ssh_host_ed25519_key
docker_host_secret_dir=/run/secrets/docker-host
docker_host_source="$docker_host_secret_dir/docker_host"
docker_ssh_alias_source="$docker_host_secret_dir/ssh_alias"
docker_ssh_host_source="$docker_host_secret_dir/ssh_host"
docker_ssh_port_source="$docker_host_secret_dir/ssh_port"
docker_ssh_user_source="$docker_host_secret_dir/ssh_user"
docker_client_key_source="$docker_host_secret_dir/ssh_client_ed25519_private_key"
docker_client_fingerprint_source="$docker_host_secret_dir/ssh_client_ed25519_fingerprint"
docker_host_fingerprint_source="$docker_host_secret_dir/ssh_host_ed25519_fingerprint"
docker_known_hosts_source="$docker_host_secret_dir/ssh_known_hosts"
runtime_dir=/run/codex-remote-devbox
authorized_keys_runtime="$runtime_dir/authorized_keys"
host_key_runtime="$runtime_dir/ssh_host_ed25519_key"
authorized_keys_validation="$runtime_dir/authorized_keys.validation"
authorized_key_validation="$runtime_dir/authorized_key.validation"
docker_host_runtime_dir="$runtime_dir/docker-host"
docker_client_key_runtime="$docker_host_runtime_dir/ssh_client_ed25519_private_key"
docker_known_hosts_runtime="$docker_host_runtime_dir/ssh_known_hosts"
docker_ssh_client_config=/etc/ssh/ssh_config.d/20-codex-docker-host.conf
runtime_sshd_config="$runtime_dir/sshd_config"
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

read_secret_scalar() {
  LC_ALL=C awk '
    NR == 1 {
      value = $0
      next
    }
    { invalid = 1 }
    END {
      if (invalid || NR != 1 || length(value) == 0 || value !~ /^[ -~]+$/) {
        exit 1
      }
      printf "%s", value
    }
  ' "$1"
}

is_sha256_fingerprint() {
  printf '%s\n' "$1" | awk '
    NR != 1 { invalid = 1 }
    NR == 1 {
      if (length($0) != 50 ||
          substr($0, 1, 7) != "SHA256:" ||
          substr($0, 8) !~ /^[A-Za-z0-9+\/]+$/) {
        invalid = 1
      }
    }
    END {
      if (invalid || NR != 1) {
        exit 1
      }
    }
  '
}

is_safe_ssh_hostname() {
  case "$1" in
    *:*)
      printf '%s\n' "$1" | python3 -c '
import ipaddress
import sys

value = sys.stdin.read()
if value.endswith("\n"):
    value = value[:-1]
ipaddress.IPv6Address(value)
' >/dev/null 2>&1
      ;;
    *)
      printf '%s\n' "$1" | awk '
        NR != 1 { invalid = 1 }
        NR == 1 {
          if (length($0) == 0 || length($0) > 253 ||
              $0 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$/) {
            if (length($0) != 1 || $0 !~ /^[A-Za-z0-9]$/) {
              invalid = 1
            }
          }
          label_count = split($0, labels, ".")
          for (label_index = 1; label_index <= label_count; label_index++) {
            if (length(labels[label_index]) == 0 ||
                length(labels[label_index]) > 63 ||
                labels[label_index] !~ /^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$/) {
              invalid = 1
            }
          }
        }
        END {
          if (invalid || NR != 1) {
            exit 1
          }
        }
      '
      ;;
  esac
}

is_safe_ssh_user() {
  printf '%s\n' "$1" | awk '
    NR != 1 { invalid = 1 }
    NR == 1 {
      if (length($0) == 0 || length($0) > 255 ||
          $0 !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/) {
        invalid = 1
      }
    }
    END {
      if (invalid || NR != 1) {
        exit 1
      }
    }
  '
}

is_safe_ssh_port() {
  printf '%s\n' "$1" | awk '
    NR != 1 { invalid = 1 }
    NR == 1 {
      if ($0 !~ /^[0-9]+$/ || length($0) > 5 || $0 + 0 < 1 || $0 + 0 > 65535) {
        invalid = 1
      }
    }
    END {
      if (invalid || NR != 1) {
        exit 1
      }
    }
  '
}

is_safe_docker_host_uri() {
  case "$1" in
    ssh://docker-host/*)
      docker_socket_path=${1#ssh://docker-host}
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\n' "$docker_socket_path" | awk '
    NR != 1 { invalid = 1 }
    NR == 1 {
      if (length($0) < 2 || length($0) > 4096 ||
          $0 !~ /^\/[A-Za-z0-9._~\/-]+$/ ||
          index($0, "//") != 0 ||
          $0 ~ /(^|\/)\.\.?($|\/)/ ||
          substr($0, length($0), 1) == "/") {
        invalid = 1
      }
    }
    END {
      if (invalid || NR != 1) {
        exit 1
      }
    }
  '
}

validate_effective_docker_ssh_config() {
  awk \
    -v expected_alias="$1" \
    -v expected_hostname="$2" \
    -v expected_user="$3" \
    -v expected_port="$4" \
    -v expected_identity_file="$5" \
    -v expected_known_hosts_file="$6" '
    function check_value(name, actual, expected) {
      seen[name]++
      if (seen[name] != 1 || NF != 2 || actual != expected) {
        invalid = 1
      }
    }

    $1 == "host" {
      check_value("host", $2, expected_alias)
      next
    }
    $1 == "hostname" {
      check_value("hostname", $2, expected_hostname)
      next
    }
    $1 == "user" {
      check_value("user", $2, expected_user)
      next
    }
    $1 == "port" {
      check_value("port", $2, expected_port)
      next
    }
    $1 == "identityfile" {
      check_value("identityfile", $2, expected_identity_file)
      next
    }
    $1 == "identitiesonly" {
      check_value("identitiesonly", $2, "yes")
      next
    }
    $1 == "batchmode" {
      check_value("batchmode", $2, "yes")
      next
    }
    $1 == "preferredauthentications" {
      check_value("preferredauthentications", $2, "publickey")
      next
    }
    $1 == "passwordauthentication" {
      check_value("passwordauthentication", $2, "no")
      next
    }
    $1 == "kbdinteractiveauthentication" {
      check_value("kbdinteractiveauthentication", $2, "no")
      next
    }
    $1 == "stricthostkeychecking" {
      check_value("stricthostkeychecking", $2, "true")
      next
    }
    $1 == "userknownhostsfile" {
      check_value("userknownhostsfile", $2, expected_known_hosts_file)
      next
    }
    $1 == "hostkeyalgorithms" {
      check_value("hostkeyalgorithms", $2, "ssh-ed25519")
      next
    }
    $1 == "hostkeyalias" {
      check_value("hostkeyalias", $2, expected_alias)
      next
    }
    $1 == "updatehostkeys" {
      check_value("updatehostkeys", $2, "false")
      next
    }
    $1 == "forwardagent" {
      check_value("forwardagent", $2, "no")
      next
    }

    END {
      if (seen["host"] != 1 ||
          seen["hostname"] != 1 ||
          seen["user"] != 1 ||
          seen["port"] != 1 ||
          seen["identityfile"] != 1 ||
          seen["identitiesonly"] != 1 ||
          seen["batchmode"] != 1 ||
          seen["preferredauthentications"] != 1 ||
          seen["passwordauthentication"] != 1 ||
          seen["kbdinteractiveauthentication"] != 1 ||
          seen["stricthostkeychecking"] != 1 ||
          seen["userknownhostsfile"] != 1 ||
          seen["hostkeyalgorithms"] != 1 ||
          seen["hostkeyalias"] != 1 ||
          seen["updatehostkeys"] != 1 ||
          seen["forwardagent"] != 1) {
        invalid = 1
      }
      if (invalid) {
        exit 1
      }
    }
  '
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

[ ! -L "$docker_host_secret_dir" ] \
  || fail "required Docker host Secret directory is a symbolic link"
[ -e "$docker_host_secret_dir" ] \
  || fail "required Docker host Secret directory is missing"
[ -d "$docker_host_secret_dir" ] \
  || fail "required Docker host Secret path is not a directory"

for required_file in \
  "$docker_host_source" \
  "$docker_ssh_alias_source" \
  "$docker_ssh_host_source" \
  "$docker_ssh_port_source" \
  "$docker_ssh_user_source" \
  "$docker_client_key_source" \
  "$docker_client_fingerprint_source" \
  "$docker_host_fingerprint_source" \
  "$docker_known_hosts_source"; do
  [ ! -L "$required_file" ] \
    || fail "required Docker host Secret input is a symbolic link: $required_file"
  [ -e "$required_file" ] \
    || fail "required Docker host Secret input is missing: $required_file"
  [ -f "$required_file" ] \
    || fail "required Docker host Secret input is not a regular file: $required_file"
  [ -r "$required_file" ] \
    || fail "required Docker host Secret input is unreadable: $required_file"
  [ -s "$required_file" ] \
    || fail "required Docker host Secret input is empty: $required_file"
done

docker_host="$(read_secret_scalar "$docker_host_source")" \
  || fail "Docker host URI must be a single nonempty line"
docker_ssh_alias="$(read_secret_scalar "$docker_ssh_alias_source")" \
  || fail "Docker host SSH alias must be a single nonempty line"
docker_ssh_host="$(read_secret_scalar "$docker_ssh_host_source")" \
  || fail "Docker host SSH hostname must be a single nonempty line"
docker_ssh_port="$(read_secret_scalar "$docker_ssh_port_source")" \
  || fail "Docker host SSH port must be a single nonempty line"
docker_ssh_user="$(read_secret_scalar "$docker_ssh_user_source")" \
  || fail "Docker host SSH user must be a single nonempty line"
docker_client_fingerprint="$(read_secret_scalar "$docker_client_fingerprint_source")" \
  || fail "Docker host client key fingerprint must be a single nonempty line"
docker_host_fingerprint="$(read_secret_scalar "$docker_host_fingerprint_source")" \
  || fail "Docker host key fingerprint must be a single nonempty line"

[ "$docker_ssh_alias" = docker-host ] \
  || fail "Docker host SSH alias must be docker-host"
is_safe_ssh_hostname "$docker_ssh_host" \
  || fail "Docker host SSH hostname is invalid"
is_safe_ssh_port "$docker_ssh_port" \
  || fail "Docker host SSH port is invalid"
is_safe_ssh_user "$docker_ssh_user" \
  || fail "Docker host SSH user is invalid"
is_safe_docker_host_uri "$docker_host" \
  || fail "Docker host URI is invalid"
is_sha256_fingerprint "$docker_client_fingerprint" \
  || fail "Docker host client key fingerprint is invalid"
is_sha256_fingerprint "$docker_host_fingerprint" \
  || fail "Docker host key fingerprint is invalid"

install -d -o root -g root -m 0755 /run/sshd
install -d -o root -g root -m 0755 "$runtime_dir"
install -d -o root -g root -m 0755 "$docker_host_runtime_dir"
install -d -o root -g root -m 0755 /etc/ssh/ssh_config.d
install -o root -g root -m 0644 "$authorized_keys_source" "$authorized_keys_runtime"
install -o root -g root -m 0600 "$host_key_source" "$host_key_runtime"
install -o root -g root -m 0600 /dev/null "$authorized_keys_validation"
install -o root -g root -m 0600 /dev/null "$authorized_key_validation"
install -o 1000 -g 1000 -m 0600 "$docker_client_key_source" "$docker_client_key_runtime" \
  || fail "could not materialize Docker host client key"
install -o 1000 -g 1000 -m 0600 "$docker_known_hosts_source" "$docker_known_hosts_runtime" \
  || fail "could not materialize Docker host known_hosts"

[ "$(stat -c '%u:%g:%a' -- "$docker_client_key_runtime" 2>/dev/null)" = 1000:1000:600 ] \
  || fail "Docker host client key runtime metadata validation failed"
[ "$(stat -c '%u:%g:%a' -- "$docker_known_hosts_runtime" 2>/dev/null)" = 1000:1000:600 ] \
  || fail "Docker host known_hosts runtime metadata validation failed"

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

docker_client_key_type="$(
  ssh-keygen -y -P '' -f "$docker_client_key_runtime" 2>/dev/null | awk '
    NR == 1 && NF >= 2 {
      key_type = $1
      next
    }
    { invalid = 1 }
    END {
      if (invalid || NR != 1) {
        exit 1
      }
      printf "%s", key_type
    }
  '
)" || fail "Docker host client key is not a valid Ed25519 private key"
[ "$docker_client_key_type" = ssh-ed25519 ] \
  || fail "Docker host client key is not a valid Ed25519 private key"

docker_client_fingerprint_derived="$(
  ssh-keygen -y -P '' -f "$docker_client_key_runtime" 2>/dev/null \
    | ssh-keygen -l -E sha256 -f - 2>/dev/null \
    | awk '
        NR == 1 && NF >= 2 {
          fingerprint = $2
          next
        }
        { invalid = 1 }
        END {
          if (invalid || NR != 1 || length(fingerprint) == 0) {
            exit 1
          }
          printf "%s", fingerprint
        }
      '
)" || fail "Docker host client key fingerprint derivation failed"
[ "$docker_client_fingerprint_derived" = "$docker_client_fingerprint" ] \
  || fail "Docker host client key fingerprint does not match"

docker_known_hosts_target=$docker_ssh_alias

if ! awk -v expected_target="$docker_known_hosts_target" '
  NR == 1 && NF == 3 &&
    $1 == expected_target &&
    $2 == "ssh-ed25519" &&
    $3 ~ /^[A-Za-z0-9+\/=]+$/ {
      valid = 1
      next
    }
  { invalid = 1 }
  END {
    if (invalid || NR != 1 || !valid) {
      exit 1
    }
  }
' "$docker_known_hosts_runtime"; then
  fail "Docker host known_hosts must contain exactly one matching Ed25519 entry"
fi

docker_host_fingerprint_derived="$(
  ssh-keygen -l -E sha256 -f "$docker_known_hosts_runtime" 2>/dev/null | awk '
    NR == 1 && NF >= 2 {
      fingerprint = $2
      next
    }
    { invalid = 1 }
    END {
      if (invalid || NR != 1 || length(fingerprint) == 0) {
        exit 1
      }
      printf "%s", fingerprint
    }
  '
)" || fail "Docker host known_hosts fingerprint derivation failed"
[ "$docker_host_fingerprint_derived" = "$docker_host_fingerprint" ] \
  || fail "Docker host known_hosts fingerprint does not match"

unset \
  docker_client_fingerprint \
  docker_client_fingerprint_derived \
  docker_client_key_type \
  docker_host_fingerprint \
  docker_host_fingerprint_derived \
  docker_known_hosts_target

install -o root -g root -m 0644 /dev/null "$docker_ssh_client_config" \
  || fail "could not create Docker host SSH client configuration"
if ! {
  printf '%s\n' \
    "Host $docker_ssh_alias" \
    "  HostName $docker_ssh_host" \
    "  User $docker_ssh_user" \
    "  Port $docker_ssh_port" \
    "  IdentityFile $docker_client_key_runtime" \
    "  IdentitiesOnly yes" \
    "  BatchMode yes" \
    "  PreferredAuthentications publickey" \
    "  PasswordAuthentication no" \
    "  KbdInteractiveAuthentication no" \
    "  StrictHostKeyChecking yes" \
    "  UserKnownHostsFile $docker_known_hosts_runtime" \
    "  HostKeyAlgorithms ssh-ed25519" \
    "  HostKeyAlias $docker_ssh_alias" \
    "  UpdateHostKeys no" \
    "  ForwardAgent no"
} > "$docker_ssh_client_config"; then
  fail "could not write Docker host SSH client configuration"
fi
[ "$(stat -c '%u:%g:%a' -- "$docker_ssh_client_config" 2>/dev/null)" = 0:0:644 ] \
  || fail "Docker host SSH client configuration metadata validation failed"

if ! /usr/bin/ssh -G -F /etc/ssh/ssh_config "$docker_ssh_alias" 2>/dev/null \
  | validate_effective_docker_ssh_config \
      "$docker_ssh_alias" \
      "$docker_ssh_host" \
      "$docker_ssh_user" \
      "$docker_ssh_port" \
      "$docker_client_key_runtime" \
      "$docker_known_hosts_runtime"; then
  fail "Docker host SSH client configuration validation failed"
fi

install -o root -g root -m 0600 /etc/ssh/sshd_config "$runtime_sshd_config" \
  || fail "could not create OpenSSH runtime configuration"
if ! printf '\nSetEnv DOCKER_HOST=%s\n' "$docker_host" >> "$runtime_sshd_config"; then
  fail "could not write OpenSSH runtime configuration"
fi
[ "$(stat -c '%u:%g:%a' -- "$runtime_sshd_config" 2>/dev/null)" = 0:0:600 ] \
  || fail "OpenSSH runtime configuration metadata validation failed"

/usr/sbin/sshd -t -f "$runtime_sshd_config" >/dev/null 2>&1 \
  || fail "OpenSSH runtime configuration validation failed"

for state_root in /home/codex /workspaces; do
  bootstrap_state_root "$state_root"
done

if ! sudo -n -H -u codex -- /usr/bin/ssh -G "$docker_ssh_alias" 2>/dev/null \
  | validate_effective_docker_ssh_config \
      "$docker_ssh_alias" \
      "$docker_ssh_host" \
      "$docker_ssh_user" \
      "$docker_ssh_port" \
      "$docker_client_key_runtime" \
      "$docker_known_hosts_runtime"; then
  fail "effective Docker host SSH client configuration validation failed"
fi

trap - HUP INT TERM
exec /usr/sbin/sshd -D -e -f "$runtime_sshd_config"
