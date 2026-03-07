#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/start_ambient_patient.sh <SERVER_IP>

Example:
  ./scripts/start_ambient_patient.sh 160.211.46.40

What this script does:
  1) Exports SERVER_IP for compose interpolation
  2) Starts/restarts TURN server
  3) Builds and starts agent backend (app-server)
  4) Builds and starts ACE services (python-app, ui-app)
  5) Prints container status and next UI URL
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Error: missing SERVER_IP"
  usage
  exit 1
fi

SERVER_IP_INPUT="$1"
if [[ ! "$SERVER_IP_INPUT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Error: SERVER_IP must be an IPv4 address (got: $SERVER_IP_INPUT)"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ACE_DIR="$REPO_ROOT/ambient-patient/ace-controller-voice-interface"
AGENT_DIR="$REPO_ROOT/ambient-patient/agent"

if [[ ! -f "$ACE_DIR/docker-compose.yml" ]]; then
  echo "Error: ACE compose file not found at $ACE_DIR/docker-compose.yml"
  exit 1
fi

if [[ ! -f "$AGENT_DIR/docker-compose.yaml" ]]; then
  echo "Error: agent compose file not found at $AGENT_DIR/docker-compose.yaml"
  exit 1
fi

export SERVER_IP="$SERVER_IP_INPUT"
export USERID="$(id -u):$(id -g)"

echo "Using SERVER_IP=$SERVER_IP"
echo "Using USERID=$USERID"

echo "[1/5] Restarting TURN server..."
docker rm -f turn-server >/dev/null 2>&1 || true
docker run -d \
  --name turn-server \
  --network host \
  instrumentisto/coturn \
  -n --verbose \
  --log-file=stdout \
  --external-ip="$SERVER_IP" \
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

echo "[2/5] Starting agent backend (app-server)..."
(
  cd "$AGENT_DIR"
  docker compose -f docker-compose.yaml up -d --build app-server
)

echo "[3/5] Starting ACE services..."
(
  cd "$ACE_DIR"
  docker compose --profile ace-controller down
  docker compose --profile ace-controller up -d --build
)

echo "[4/5] Container status..."
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "voice-agents-webrtc|app-server-healthcare-assistant|turn-server" || true

echo "[5/5] Done"
echo "Open UI: http://$SERVER_IP:4400"
echo "If needed, tail logs:"
echo "  cd $ACE_DIR && docker compose --profile ace-controller logs -f --tail=200 ui-app python-app"
echo "  cd $AGENT_DIR && docker compose -f docker-compose.yaml logs -f --tail=200 app-server"
