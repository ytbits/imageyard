#!/usr/bin/env bash
# Sourced by smoke-test.sh; uses disposable state and no App Server credentials.

gateway_http_status() {
  docker exec "$gateway_container" curl --silent --output /dev/null \
    --write-out '%{http_code}' --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:8787/$1"
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
  fail 'optional App Server relay did not become ready'
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
  fail 'optional App Server relay did not recover'
}

gateway_client_smoke() {
  # A second container connects straight to the target IP without a Service,
  # Authorization header or TLS options. No model request is performed.
  local direct_ip
  direct_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$gateway_container")"
  [ -n "$direct_ip" ] || fail 'direct relay fixture address is unavailable'
  docker run --rm --name "$gateway_client_container" \
    --network "$docker_backend_network" --entrypoint /usr/local/bin/node \
    --mount "type=bind,src=$script_dir/examples/app-server-client,dst=/opt/client,readonly" \
    --env "CODEX_APP_SERVER_URL=ws://$direct_ip:8787" \
    "$image" /opt/client/integration-smoke.ts
}

run_app_server_gateway_smoke() {
  [ -d "$script_dir/examples/app-server-client/node_modules/ws" ] \
    || fail 'run npm ci in examples/app-server-client before container smoke'
  gateway_container="${name_prefix}-gateway"
  gateway_client_container="${name_prefix}-gateway-client"
  local mismatch_container="${name_prefix}-gateway-mismatch"
  local gateway_home="${name_prefix}-gateway-home"
  local gateway_workspace="${name_prefix}-gateway-workspace"
  local mismatch_home="${name_prefix}-mismatch-home"
  local mismatch_workspace="${name_prefix}-mismatch-workspace"
  cleanup_containers+=("$gateway_container" "$gateway_client_container" "$mismatch_container")
  for volume_name in "$gateway_home" "$gateway_workspace" "$mismatch_home" "$mismatch_workspace"; do
    create_state_volume "$volume_name"
  done

  start_container "$gateway_container" "$gateway_home" "$gateway_workspace" \
    "$fixture_dir/docker-host" "$docker_backend_network" \
    --hostname codex-devbox-2 --env CODEX_APP_SERVER_ENABLED=1 --env CODEX_APP_SERVER_ORDINAL=2 \
    --mount "type=bind,src=$script_dir/examples/app-server-client,dst=/opt/client,readonly"
  local gateway_known_hosts="$fixture_dir/known_hosts.gateway"
  local gateway_ssh_port
  gateway_ssh_port="$(wait_for_ssh "$gateway_container" "$gateway_known_hosts")"
  wait_for_gateway
  [ "$(gateway_http_status livez)" = 200 ] || fail 'relay liveness failed'
  docker exec "$gateway_container" sh -ec '
    test ! -e /run/secrets/app-server
    test ! -e /run/codex-remote-devbox/app-server
  ' || fail 'relay unexpectedly requires staged credentials'
  gateway_client_smoke

  # Both desktop-style stdio proxy and plain WS attach to the SAME Unix daemon.
  ssh_command "$gateway_known_hosts" "$gateway_ssh_port" "$fixture_dir/client_key" codex \
    'CODEX_APP_SERVER_URL=ws://127.0.0.1:8787 node /opt/client/proxy-smoke.ts'

  local daemon_pid worker_pid new_daemon_pid attempt
  daemon_pid="$(managed_daemon_pid)"
  [[ "$daemon_pid" =~ ^[0-9]+$ ]] || fail 'expected exactly one managed Codex daemon'
  worker_pid="$(container_exact_process_pid "$gateway_container" \
    '/usr/local/bin/node /usr/local/libexec/app-server-gateway.js')"
  docker exec "$gateway_container" kill -TERM "$worker_pid"
  wait_for_gateway_worker_change "$worker_pid"
  [ "$(managed_daemon_pid)" = "$daemon_pid" ] || fail 'relay restart replaced the desktop daemon'
  gateway_client_smoke

  docker exec "$gateway_container" kill -TERM "$daemon_pid"
  new_daemon_pid=''
  for attempt in $(seq 1 90); do
    new_daemon_pid="$(managed_daemon_pid 2>/dev/null || true)"
    if [[ "$new_daemon_pid" =~ ^[0-9]+$ ]] && [ "$new_daemon_pid" != "$daemon_pid" ] && \
        [ "$(gateway_http_status readyz 2>/dev/null || true)" = 200 ]; then break; fi
    sleep 0.5
  done
  [[ "$new_daemon_pid" =~ ^[0-9]+$ ]] && [ "$new_daemon_pid" != "$daemon_pid" ] \
    || fail 'managed daemon was not recovered'
  wait_for_gateway
  gateway_client_smoke
  ssh_command "$gateway_known_hosts" "$gateway_ssh_port" "$fixture_dir/client_key" codex 'true'

  start_container "$mismatch_container" "$mismatch_home" "$mismatch_workspace" \
    "$fixture_dir/docker-host" "$docker_backend_network" \
    --hostname codex-devbox-1 --env CODEX_APP_SERVER_ENABLED=1 --env CODEX_APP_SERVER_ORDINAL=2
  wait_for_ssh "$mismatch_container" "$fixture_dir/known_hosts.mismatch" >/dev/null
  if docker exec "$mismatch_container" pgrep -u 1000 -x codex >/dev/null; then
    fail 'non-canary ordinal prestarted Codex'
  fi
  if docker exec "$mismatch_container" sh -c 'ss -H -lnt | grep -q :8787'; then
    fail 'non-canary ordinal opened the App Server port'
  fi
  docker logs "$gateway_container" > "$fixture_dir/gateway.log" 2>&1
  assert_log_excludes_key_material "$fixture_dir/gateway.log"
  printf 'Direct App Server WS without credentials, desktop coexistence and recovery smoke passed\n'
}
