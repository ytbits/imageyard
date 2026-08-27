#!/bin/sh

set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

fail() {
  printf '%s\n' 'codex-remote-devbox: GHCR Docker configuration failed' >&2
  exit 1
}

[ "$#" -eq 1 ] || fail

case "$1" in
  enable|disable|scrub-legacy-auth) ;;
  *) fail ;;
esac

[ "$(/usr/bin/id -u 2>/dev/null)" = 1000 ] || fail
[ "$(/usr/bin/id -g 2>/dev/null)" = 1000 ] || fail

lock_file=/run/codex-remote-devbox/ghcr-auth.lock
[ ! -L "$lock_file" ] || fail
[ -f "$lock_file" ] || fail
[ "$(/usr/bin/stat -c '%u:%g:%a:%h' -- "$lock_file" 2>/dev/null)" = 1000:1000:600:1 ] || fail

if ! /usr/bin/env -i \
  HOME=/home/codex \
  LANG=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/bin/flock \
    --exclusive \
    --timeout 30 \
    "$lock_file" \
    /usr/local/bin/node \
    /usr/local/libexec/ghcr-auth-config.js \
    "$1" \
    2>/dev/null; then
  fail
fi
