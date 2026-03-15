#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./script/start_ambient_patient.sh <BREV_SERVER_IP>

Example:
  ./script/start_ambient_patient.sh 160.211.46.40

Starts these 4 containers:
  1) turn-server
  2) app-server-healthcare-assistant
  3) voice-agents-webrtc-python-app-1
  4) voice-agents-webrtc-ui-app-1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  echo "Error: expected exactly one BREV_SERVER_IP argument"
  usage
  exit 1
fi

BREV_SERVER_IP="$1"
if [[ ! "$BREV_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Error: BREV_SERVER_IP must be an IPv4 address (got: $BREV_SERVER_IP)"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$REPO_ROOT/ace-controller-voice-interface/docker-compose.yml" && -f "$REPO_ROOT/agent/docker-compose.yaml" ]]; then
  ACE_DIR="$REPO_ROOT/ace-controller-voice-interface"
  AGENT_DIR="$REPO_ROOT/agent"
elif [[ -f "$REPO_ROOT/ambient-patient/ace-controller-voice-interface/docker-compose.yml" && -f "$REPO_ROOT/ambient-patient/agent/docker-compose.yaml" ]]; then
  ACE_DIR="$REPO_ROOT/ambient-patient/ace-controller-voice-interface"
  AGENT_DIR="$REPO_ROOT/ambient-patient/agent"
else
  echo "Error: could not locate ace-controller-voice-interface/ and agent/ under $REPO_ROOT"
  exit 1
fi

ACE_ENV="$ACE_DIR/ace_controller.env"
ACE_LOCAL_ENV="$ACE_DIR/ace_controller.local.env"
ACE_CONFIG="$ACE_DIR/configs/config_riva_hybrid.yaml"
AGENT_ENV="$AGENT_DIR/vars.env"
AGENT_LOCAL_ENV="$AGENT_DIR/vars.local.env"

APP_CONTAINER="app-server-healthcare-assistant"
PYTHON_CONTAINER="voice-agents-webrtc-python-app-1"
UI_CONTAINER="voice-agents-webrtc-ui-app-1"

export BREV_SERVER_IP
export SERVER_IP="$BREV_SERVER_IP"
export USERID="$(id -u):$(id -g)"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Error: required file not found: $path"
    exit 1
  fi
}

set_key_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local container="$3"
  local log_hint="$4"

  for i in $(seq 1 24); do
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)"

    if [[ "$state" == "exited" || "$state" == "dead" || "$state" == "missing" ]]; then
      echo "Error: $container is not running (state=$state)"
      docker logs --tail=120 "$container" 2>/dev/null || true
      echo "$log_hint"
      exit 1
    fi

    if curl -fsS -m 5 "$url" >/dev/null 2>&1; then
      echo "$name is ready"
      return 0
    fi

    echo "Waiting for $name ($i/24)..."
    sleep 5
  done

  echo "Error: timed out waiting for $name at $url"
  docker logs --tail=120 "$container" 2>/dev/null || true
  echo "$log_hint"
  exit 1
}

require_file "$ACE_DIR/docker-compose.yml"
require_file "$AGENT_DIR/docker-compose.yaml"
require_file "$ACE_ENV"
require_file "$ACE_CONFIG"
require_file "$AGENT_ENV"

# Determine APP_SERVER_PORT: env var > ace_controller.env > default 8082
if [[ -z "${APP_SERVER_PORT:-}" ]]; then
  APP_SERVER_PORT="$(grep -m1 '^APP_SERVER_PORT=' "$ACE_ENV" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"
  APP_SERVER_PORT="${APP_SERVER_PORT:-8082}"
fi
export APP_SERVER_PORT

echo "Using BREV_SERVER_IP=$BREV_SERVER_IP"
echo "Using ACE_DIR=$ACE_DIR"
echo "Using AGENT_DIR=$AGENT_DIR"
echo "Using APP_SERVER_PORT=$APP_SERVER_PORT"

echo "Preparing config files..."
cp "$AGENT_ENV" "$AGENT_LOCAL_ENV"
set_key_value "$ACE_ENV" "BREV_SERVER_IP" "$BREV_SERVER_IP"
set_key_value "$ACE_ENV" "TURN_SERVER_URL" "turn:${BREV_SERVER_IP}:3478"
set_key_value "$ACE_ENV" "APP_SERVER_PORT" "$APP_SERVER_PORT"
set_key_value "$ACE_ENV" "RAG_SERVER_URL" "http://app-server-healthcare-assistant:${APP_SERVER_PORT}"
cp "$ACE_ENV" "$ACE_LOCAL_ENV"

sed -i -E "s|server: \".*:50052\"|server: \"${BREV_SERVER_IP}:50052\"|" "$ACE_CONFIG"
sed -i -E "s|server: \".*:50051\"|server: \"${BREV_SERVER_IP}:50051\"|" "$ACE_CONFIG"

echo "Stopping old ACE containers..."
(
  cd "$ACE_DIR"
  docker compose --profile ace-controller down --remove-orphans || true
)

echo "Stopping old app-server container..."
(
  cd "$AGENT_DIR"
  docker compose -f docker-compose.yaml rm -sf app-server || true
)

echo "Freeing ports ${APP_SERVER_PORT} and 5678 if held by stale processes..."
fuser -k "${APP_SERVER_PORT}/tcp" 2>/dev/null || true
fuser -k "5678/tcp" 2>/dev/null || true

echo "Restarting turn-server..."
docker rm -f turn-server >/dev/null 2>&1 || true
docker run -d \
  --name turn-server \
  --network host \
  instrumentisto/coturn \
  -n --verbose \
  --log-file=stdout \
  --external-ip="$BREV_SERVER_IP" \
  --listening-ip=0.0.0.0 \
  --listening-port=3478 \
  --lt-cred-mech \
  --fingerprint \
  --user=admin:admin \
  --no-multicast-peers \
  --realm=tokkio.realm.org \
  --min-port=50000 \
  --max-port=52000 \
  --log-binding >/dev/null

echo "Ensuring clean healthcare-agent network..."
if docker network inspect healthcare-agent >/dev/null 2>&1; then
  NETWORK_LABEL="$(docker network inspect healthcare-agent --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null || true)"
  if [[ "$NETWORK_LABEL" != "healthcare-agent-network" ]]; then
    for cid in $(docker network inspect healthcare-agent --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
      docker network disconnect -f healthcare-agent "$cid" 2>/dev/null || true
    done
    docker network rm healthcare-agent >/dev/null 2>&1 || true
  fi
fi

echo "Starting app-server on ${APP_SERVER_PORT}..."
(
  cd "$AGENT_DIR"
  docker compose -f docker-compose.yaml up -d --build --force-recreate app-server
)

if ! docker ps -a --format '{{.Names}}' | grep -qx "$APP_CONTAINER"; then
  echo "Error: $APP_CONTAINER was not created"
  exit 1
fi

wait_for_http \
  "app-server" \
  "http://localhost:${APP_SERVER_PORT}/health" \
  "$APP_CONTAINER" \
  "Check logs: cd $AGENT_DIR && docker compose -f docker-compose.yaml logs --tail=200 app-server"

echo "Starting ACE python-app and ui-app..."
(
  cd "$ACE_DIR"
  docker compose --profile ace-controller up -d --build --force-recreate python-app ui-app
)

wait_for_http \
  "python-app" \
  "http://localhost:7860/get_prompt" \
  "$PYTHON_CONTAINER" \
  "Check logs: cd $ACE_DIR && docker compose --profile ace-controller logs --tail=200 python-app"

wait_for_http \
  "ui-app" \
  "http://localhost:4400" \
  "$UI_CONTAINER" \
  "Check logs: cd $ACE_DIR && docker compose --profile ace-controller logs --tail=200 ui-app"

echo
echo "Started containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'turn-server|app-server-healthcare-assistant|voice-agents-webrtc-python-app-1|voice-agents-webrtc-ui-app-1' || true

echo
echo "Open UI: http://localhost:4400"
echo "Backend health: http://localhost:${APP_SERVER_PORT}/health"
echo "Python app: http://localhost:7860/get_prompt"
