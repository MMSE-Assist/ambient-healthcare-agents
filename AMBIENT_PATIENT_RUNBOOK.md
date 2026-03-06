# Ambient Patient Runbook (Brev + Remote Riva + TURN)

This document captures the final working setup.

## Scope
- Ambient Patient UI + Python app from `ace-controller-voice-interface`
- Agent assistant backend from `ambient-patient/agent` (FastAPI on port `8081`)
- Remote Riva models on Brev host `${SERVER_IP}`
- TURN server on Brev host for WebRTC connectivity

## Prerequisites
- Docker and Docker Compose installed
- Local clone path exported as `WORKSPACE_ROOT` (example: `export WORKSPACE_ROOT=$HOME/<your-workspace>`)
- Brev ports exposed:
  - `4400` TCP
  - `7860` TCP
  - `3478` TCP/UDP
  - `50000-52000` UDP

---

## 0) Before start: log into Brev and capture current server IP

```bash
export WORKSPACE_ROOT="$HOME/<your-workspace>"
cd "$WORKSPACE_ROOT"

# replace with your own Brev instance name
brev shell <brev-instance-name>

export SERVER_IP="$(curl -s https://ifconfig.me | tr -d '\n')"
echo "$SERVER_IP"
```

Use this `${SERVER_IP}` value in the steps below.

## 1) Go to project directory

```bash
cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/ace-controller-voice-interface"
```

## 2) Verify app env config

File: `ace_controller.env`

Required values:

```dotenv
CONFIG_PATH=./configs/config_riva_hybrid.yaml
TURN_USERNAME=admin
TURN_PASSWORD=admin
TURN_SERVER_URL=turn:${SERVER_IP}:3478
```

## 3) Verify remote Riva endpoints

File: `configs/config_riva_hybrid.yaml`

Required values:

```yaml
RivaASRService:
  server: "${SERVER_IP}:50052"

RivaTTSService:
  server: "${SERVER_IP}:50051"
```

## 4) Start/restart TURN server (on Brev)

```bash
docker rm -f turn-server 2>/dev/null || true

docker run -d \
  --name turn-server \
  --network host \
  instrumentisto/coturn \
  -n --verbose \
  --log-file=stdout \
  --external-ip=${SERVER_IP} \
  --listening-ip=0.0.0.0 \
  --listening-port=3478 \
  --lt-cred-mech \
  --fingerprint \
  --user=admin:admin \
  --no-multicast-peers \
  --realm=tokkio.realm.org \
  --min-port=50000 \
  --max-port=52000 \
  --log-binding
```

## 5) Start the agent assistant backend

The ACE Python app calls the agent backend at `http://app-server-healthcare-assistant:8081`, so start this first.

```bash
cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/agent"

export USERID="$(id -u):$(id -g)"
docker compose -f docker-compose.yaml up -d --build app-server
```

Verify backend runtime:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep app-server-healthcare-assistant
docker compose -f docker-compose.yaml logs -f --tail=200 app-server
```

If using hosted NVIDIA API for LLMs, ensure in `ambient-patient/agent/vars.env`:

```dotenv
AGENT_LLM_BASE_URL="https://integrate.api.nvidia.com/v1"
AGENT_LLM_MODEL="meta/llama-3.3-70b-instruct"
```

## 6) Start ACE app services

```bash
docker compose --profile ace-controller down
docker compose --profile ace-controller up -d --build
```

## 7) Verify runtime

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
docker exec voice-agents-webrtc-python-app-1 env | grep TURN
docker compose --profile ace-controller logs -f --tail=200 ui-app python-app
```

Expected:
- `voice-agents-webrtc-python-app-1` healthy
- `voice-agents-webrtc-ui-app-1` up
- `app-server-healthcare-assistant` up on `8081`
- `turn-server` up
- No Riva connection exceptions in `python-app` logs

## 8) Open UI correctly

Use:

```text
http://${SERVER_IP}:4400
```

Do **not** use localhost for this deployment.

## 9) Chrome microphone permission workaround

1. Open `chrome://flags/#unsafely-treat-insecure-origin-as-secure`
2. Add:
  - `http://${SERVER_IP}:4400`
3. Relaunch Chrome fully

---

## Quick restart commands

```bash
# Restart agent assistant backend
cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/agent"
docker compose -f docker-compose.yaml restart app-server

# Restart ACE services
cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/ace-controller-voice-interface"

docker compose --profile ace-controller down && docker compose --profile ace-controller up -d
```

## Full restart after IP change

Run this exact sequence after `${SERVER_IP}` changes:

```bash
export WORKSPACE_ROOT="$HOME/<your-workspace>"
cd "$WORKSPACE_ROOT"
brev shell <brev-instance-name>
export SERVER_IP="$(curl -s https://ifconfig.me | tr -d '\n')"
echo "$SERVER_IP"

cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/ace-controller-voice-interface"
# update ace_controller.env and configs/config_riva_hybrid.yaml with ${SERVER_IP}

docker rm -f turn-server 2>/dev/null || true
docker run -d \
  --name turn-server \
  --network host \
  instrumentisto/coturn \
  -n --verbose \
  --log-file=stdout \
  --external-ip=${SERVER_IP} \
  --listening-ip=0.0.0.0 \
  --listening-port=3478 \
  --lt-cred-mech \
  --fingerprint \
  --user=admin:admin \
  --no-multicast-peers \
  --realm=tokkio.realm.org \
  --min-port=50000 \
  --max-port=52000 \
  --log-binding

cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/agent"
export USERID="$(id -u):$(id -g)"
docker compose -f docker-compose.yaml up -d --build app-server

cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/ace-controller-voice-interface"
docker compose --profile ace-controller down
docker compose --profile ace-controller up -d --build
```

TURN restart:

```bash
docker rm -f turn-server 2>/dev/null || true
# rerun the docker run command from section 4
```

---

## Troubleshooting

### A) `ICE checking` then `failed` / WebSocket close `1005`
- Confirm Brev ports are open (`3478` TCP/UDP, `50000-52000` UDP)
- Confirm UI is opened via `http://${SERVER_IP}:4400`
- Tail TURN logs during connect:

```bash
docker logs -f turn-server
```

If logs stay empty while clicking **Start**, TURN traffic is not reaching the host (network/security group issue).

### B) Riva errors (`StatusCode.UNAVAILABLE`)
- Check `configs/config_riva_hybrid.yaml` endpoints
- Validate remote services:

```bash
curl -sS --max-time 5 http://${SERVER_IP}:9000/v1/health/live
curl -sS --max-time 5 http://${SERVER_IP}:9002/v1/health/live
```

### C) Stale UI config after changes
Rebuild UI only:

```bash
docker compose --profile ace-controller up -d --build --no-deps ui-app
```

Then hard refresh browser (`Ctrl+Shift+R`).

### D) Agent assistant errors / `504 Gateway Timeout`
- Check backend logs:

```bash
cd "$WORKSPACE_ROOT/ambient-healthcare-agents/ambient-patient/agent"
docker compose -f docker-compose.yaml logs -f --tail=200 app-server
```

- `504` from NVIDIA public endpoint means upstream inference timeout, not container startup failure.
