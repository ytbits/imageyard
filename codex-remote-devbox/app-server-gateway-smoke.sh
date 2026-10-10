#!/usr/bin/env bash
# Sourced by smoke-test.sh; reuses its disposable keys, volumes and cleanup trap.

gateway_http_status() {
  docker exec "$gateway_container" curl --silent --output /dev/null \
    --write-out '%{http_code}' --connect-timeout 2 --max-time 5 \
    --cacert /run/secrets/app-server/tls.crt \
    --resolve app-server-smoke.invalid:8443:127.0.0.1 \
    "https://app-server-smoke.invalid:8443/$1" "${@:2}"
}

managed_daemon_pid() {
  # Codex also runs a pid-update-loop helper; select the actual App Server only.
  docker exec "$gateway_container" pgrep -u 1000 -f \
    '^/home/codex/.codex/packages/app-server-daemon/releases/[^/]+/bin/codex app-server .*--managed-daemon$'
}

wait_for_gateway() {
  local attempt
  for attempt in $(seq 1 90); do
    if [ "$(gateway_http_status readyz 2>/dev/null || true)" = 200 ]; then return; fi
    sleep 0.5
  done
  docker logs "$gateway_container" >&2 || true
  fail 'optional App Server gateway did not become ready'
}

wait_for_gateway_worker_change() {
  local previous_pid="$1"
  local attempt current_pid
  for attempt in $(seq 1 90); do
    current_pid="$(container_exact_process_pid "$gateway_container" \
      '/usr/local/bin/node /usr/local/libexec/app-server-gateway.js' 2>/dev/null || true)"
    if [ -n "$current_pid" ] && [ "$current_pid" != "$previous_pid" ] && \
        [ "$(gateway_http_status readyz 2>/dev/null || true)" = 200 ]; then return; fi
    sleep 0.5
  done
  fail 'optional App Server gateway did not restart with fresh credentials'
}

wait_for_gateway_closed() {
  local attempt
  for attempt in $(seq 1 60); do
    if ! docker exec "$gateway_container" sh -c 'ss -H -lnt | grep -q :8443'; then return; fi
    sleep 0.5
  done
  fail 'gateway listener remained open after credential revocation'
}

write_gateway_fixture_token() {
  # Root recreates only the synthetic source fixture, never runtime copies.
  # Atomic rename models a projected Secret generation change.
  docker run --rm --user 0:0 --entrypoint /bin/sh \
    --mount "type=bind,src=$fixture_dir/app-server,dst=/fixture" "$image" -ec '
      umask 077
      printf "%s" "$1" > /fixture/token.next
      chown 0:0 /fixture/token.next
      chmod 0400 /fixture/token.next
      mv -f /fixture/token.next /fixture/token
    ' fixture "$1"
}

gateway_client_smoke() {
  # A separate container exercises DNS, TLS and the network interface. No model
  # credential is provided and the client only reads config and thread metadata.
  docker run --rm --name "$gateway_client_container" \
    --network "$docker_backend_network" --entrypoint /usr/local/bin/node \
    --mount "type=bind,src=$script_dir/examples/app-server-client,dst=/opt/client,readonly" \
    --mount "type=bind,src=$fixture_dir/app-server,dst=/run/secrets/app-server,readonly" \
    --env "CODEX_APP_SERVER_URL=wss://$gateway_container:8443" \
    --env CODEX_APP_SERVER_TLS_SERVER_NAME=app-server-smoke.invalid \
    --env CODEX_APP_SERVER_TOKEN_FILE=/run/secrets/app-server/token \
    --env CODEX_APP_SERVER_CA_FILE=/run/secrets/app-server/tls.crt \
    "$image" /opt/client/integration-smoke.ts
}

run_app_server_gateway_smoke() {
  [ -d "$script_dir/examples/app-server-client/node_modules/ws" ] \
    || fail 'run npm ci in examples/app-server-client before container smoke'
  gateway_container="${name_prefix}-gateway"
  gateway_client_container="${name_prefix}-gateway-client"
  local mismatch_container="${name_prefix}-gateway-mismatch"
  local missing_container="${name_prefix}-gateway-missing"
  local missing_home="${name_prefix}-missing-home"
  local missing_workspace="${name_prefix}-missing-workspace"
  local gateway_home="${name_prefix}-gateway-home"
  local gateway_workspace="${name_prefix}-gateway-workspace"
  local mismatch_home="${name_prefix}-mismatch-home"
  local mismatch_workspace="${name_prefix}-mismatch-workspace"
  cleanup_containers+=("$gateway_container" "$gateway_client_container" "$mismatch_container" "$missing_container")
  for volume_name in "$gateway_home" "$gateway_workspace" "$mismatch_home" "$mismatch_workspace" \
      "$missing_home" "$missing_workspace"; do
    create_state_volume "$volume_name"
  done
  mkdir -p "$fixture_dir/app-server"
  docker run --rm --entrypoint /bin/sh \
    --mount "type=bind,src=$fixture_dir/app-server,dst=/fixture" "$image" -ec '
      umask 077
      openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj /CN=app-server-smoke.invalid -addext subjectAltName=DNS:app-server-smoke.invalid \
        -keyout /fixture/tls.key -out /fixture/tls.crt >/dev/null 2>&1
      printf "%s" IMAGEYARD_APP_SERVER_TOKEN_FIXTURE_NOT_REAL_1 > /fixture/token
      chmod 0400 /fixture/token /fixture/tls.key /fixture/tls.crt
    '

  start_container "$gateway_container" "$gateway_home" "$gateway_workspace" \
    "$fixture_dir/docker-host" "$docker_backend_network" \
    --hostname codex-devbox-2 --env CODEX_APP_SERVER_ENABLED=1 --env CODEX_APP_SERVER_ORDINAL=2 \
    --mount "type=bind,src=$fixture_dir/app-server,dst=/run/secrets/app-server,readonly" \
    --mount "type=bind,src=$script_dir/examples/app-server-client,dst=/opt/client,readonly"
  local gateway_known_hosts="$fixture_dir/known_hosts.gateway"
  local gateway_ssh_port
  gateway_ssh_port="$(wait_for_ssh "$gateway_container" "$gateway_known_hosts")"
  wait_for_gateway
  [ "$(gateway_http_status livez)" = 200 ] || fail 'gateway liveness failed'
  [ "$(gateway_http_status '' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')" = 401 ] \
    || fail 'gateway accepted missing authentication'
  [ "$(gateway_http_status '' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      -H 'Authorization: Bearer WRONG_IMAGEYARD_TOKEN_FIXTURE_NOT_REAL')" = 401 ] \
    || fail 'gateway accepted invalid authentication'
  gateway_client_smoke

  # Desktop-compatible stdio proxy connects to the SAME managed Unix daemon.
  ssh_command "$gateway_known_hosts" "$gateway_ssh_port" "$fixture_dir/client_key" codex \
    'CODEX_APP_SERVER_URL=wss://127.0.0.1:8443 CODEX_APP_SERVER_TLS_SERVER_NAME=app-server-smoke.invalid CODEX_APP_SERVER_TOKEN_FILE=/run/codex-remote-devbox/app-server/token CODEX_APP_SERVER_CA_FILE=/run/codex-remote-devbox/app-server/tls.crt node /opt/client/proxy-smoke.ts'

  local daemon_pid worker_pid
  daemon_pid="$(managed_daemon_pid)"
  [[ "$daemon_pid" =~ ^[0-9]+$ ]] || fail 'expected exactly one managed Codex daemon'
  worker_pid="$(container_exact_process_pid "$gateway_container" \
    '/usr/local/bin/node /usr/local/libexec/app-server-gateway.js')"
  docker exec "$gateway_container" kill -TERM "$worker_pid"
  wait_for_gateway_worker_change "$worker_pid"
  [ "$(managed_daemon_pid)" = "$daemon_pid" ] \
    || fail 'gateway restart replaced the desktop daemon'
  gateway_client_smoke

  # Rotating the projected source restarts only the optional worker. Existing
  # daemon identity and SSH remain available, and the old token must stop working.
  worker_pid="$(container_exact_process_pid "$gateway_container" \
    '/usr/local/bin/node /usr/local/libexec/app-server-gateway.js')"
  write_gateway_fixture_token IMAGEYARD_APP_SERVER_TOKEN_FIXTURE_NOT_REAL_2
  wait_for_gateway_worker_change "$worker_pid"
  [ "$(managed_daemon_pid)" = "$daemon_pid" ] \
    || fail 'credential rotation replaced the managed daemon'
  [ "$(gateway_http_status '' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      -H 'Authorization: Bearer IMAGEYARD_APP_SERVER_TOKEN_FIXTURE_NOT_REAL_1')" = 401 ] \
    || fail 'gateway accepted its previous token after rotation'
  ssh_command "$gateway_known_hosts" "$gateway_ssh_port" "$fixture_dir/client_key" codex 'true'
  gateway_client_smoke

  # Remove only the synthetic source token, not private runtime files. The
  # supervisor must close access instead of continuing with its copied token.
  worker_pid="$(container_exact_process_pid "$gateway_container" \
    '/usr/local/bin/node /usr/local/libexec/app-server-gateway.js')"
  docker run --rm --user 0:0 --entrypoint /bin/sh \
    --mount "type=bind,src=$fixture_dir/app-server,dst=/fixture" "$image" -ec 'rm /fixture/token'
  wait_for_gateway_closed
  [ "$(managed_daemon_pid)" = "$daemon_pid" ] \
    || fail 'credential revocation replaced the managed daemon'
  ssh_command "$gateway_known_hosts" "$gateway_ssh_port" "$fixture_dir/client_key" codex 'true'
  write_gateway_fixture_token IMAGEYARD_APP_SERVER_TOKEN_FIXTURE_NOT_REAL_3
  wait_for_gateway_worker_change "$worker_pid"
  [ "$(managed_daemon_pid)" = "$daemon_pid" ] \
    || fail 'credential recovery replaced the managed daemon'
  gateway_client_smoke

  docker exec "$gateway_container" kill -TERM "$daemon_pid"
  sleep 1
  wait_for_gateway
  [ "$(managed_daemon_pid)" != "$daemon_pid" ] \
    || fail 'managed daemon was not recovered'
  gateway_client_smoke
  ssh_command "$gateway_known_hosts" "$gateway_ssh_port" "$fixture_dir/client_key" codex 'true'

  # The selected canary still serves SSH when the optional Secret is absent.
  start_container "$missing_container" "$missing_home" "$missing_workspace" \
    "$fixture_dir/docker-host" "$docker_backend_network" \
    --hostname codex-devbox-2 --env CODEX_APP_SERVER_ENABLED=1 --env CODEX_APP_SERVER_ORDINAL=2
  local missing_known_hosts="$fixture_dir/known_hosts.gateway-missing"
  local missing_ssh_port
  missing_ssh_port="$(wait_for_ssh "$missing_container" "$missing_known_hosts")"
  ssh_command "$missing_known_hosts" "$missing_ssh_port" "$fixture_dir/client_key" codex 'true'
  if docker exec "$missing_container" sh -c 'ss -H -lnt | grep -q :8443'; then
    fail 'gateway opened its port without a Secret'
  fi
  if docker exec "$missing_container" pgrep -u 1000 -x codex >/dev/null; then
    fail 'missing gateway Secret prestarted a daemon'
  fi

  # A lower ordinal stays off even if the shared template includes opt-in env.
  start_container "$mismatch_container" "$mismatch_home" "$mismatch_workspace" \
    "$fixture_dir/docker-host" "$docker_backend_network" \
    --hostname codex-devbox-1 --env CODEX_APP_SERVER_ENABLED=1 --env CODEX_APP_SERVER_ORDINAL=2
  wait_for_ssh "$mismatch_container" "$fixture_dir/known_hosts.mismatch" >/dev/null
  if docker exec "$mismatch_container" pgrep -u 1000 -x codex >/dev/null; then
    fail 'non-canary ordinal prestarted Codex'
  fi
  if docker exec "$mismatch_container" sh -c 'ss -H -lnt | grep -q :8443'; then
    fail 'non-canary ordinal opened the App Server port'
  fi
  docker logs "$gateway_container" > "$fixture_dir/gateway.log" 2>&1
  assert_log_excludes_key_material "$fixture_dir/gateway.log"
  if grep -q 'IMAGEYARD_APP_SERVER_TOKEN_FIXTURE_NOT_REAL' "$fixture_dir/gateway.log"; then
    fail 'gateway leaked its token in logs'
  fi
  printf 'Optional App Server gateway TLS, auth, protocol, rotation, revocation and recovery smoke passed\n'
}
