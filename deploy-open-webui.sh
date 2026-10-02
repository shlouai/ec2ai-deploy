#!/usr/bin/env bash
#
# deploy-open-webui.sh — one-shot deploy of Open WebUI to an existing EC2 instance.
#
#   ./deploy-open-webui.sh [deploy|tunnel|status|logs|down] [options]
#
# Reads deploy.conf (or -c FILE), installs Docker + Open WebUI on the instance over
# SSH, opens a local SSH tunnel, waits for the app to come up and opens the browser.
# Re-running `deploy` upgrades the container in place; data and secret key persist.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"
COMMAND="deploy"
DRY_RUN=0
NO_BROWSER=0
DOWN_REMOTE=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Commands:
  deploy        Install/upgrade Open WebUI on the instance, open tunnel, open browser (default)
  tunnel        Only open the SSH tunnel (idempotent) and open the browser
  status        Show container state on the instance and local tunnel state
  logs          Tail the Open WebUI container logs on the instance
  down          Close the local tunnel; with --remote also stop and remove the container

Options:
  -c, --config FILE   Config file (default: ${CONFIG_FILE})
      --dry-run       Print what would run without connecting (secrets masked)
      --no-browser    Do not open the browser
      --remote        With 'down': also remove the remote container (data volume is kept)
  -h, --help          Show this help

Config keys (KEY=value, see deploy.conf.example):
  required: EC2_HOST  SSH_KEY_PATH  LLM_API_KEY
  optional: EC2_USER  SSH_PORT  SSH_EXTRA_OPTS  LOCAL_PORT  REMOTE_PORT
            LLM_API_BASE_URL  OPEN_WEBUI_IMAGE  WEBUI_NAME  DEFAULT_MODELS  RAG_EMBEDDING_MODEL
            HEALTH_TIMEOUT
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    deploy|tunnel|status|logs|down) COMMAND="$1" ;;
    -c|--config) [[ $# -ge 2 ]] || die "--config needs a value" 2; CONFIG_FILE="$2"; shift ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-browser) NO_BROWSER=1 ;;
    --remote)    DOWN_REMOTE=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# config loading
# ---------------------------------------------------------------------------
[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE (copy deploy.conf.example to deploy.conf)" 2

# Only accept plain KEY=value lines (plus comments/blank lines) before sourcing,
# so a malformed or malicious config cannot execute arbitrary commands.
bad="$(grep -nvE '^[[:space:]]*(#|$)|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE" || true)"
subst="$(grep -nE '\$\(|`' "$CONFIG_FILE" || true)"
[[ -z "$subst" ]] || bad+="${bad:+$'\n'}${subst}"
[[ -z "$bad" ]] || die "config must contain only KEY=value lines (no command substitution). Offending lines:"$'\n'"$bad" 2

# defaults (overridable from config)
EC2_USER="ec2-user"
SSH_PORT="22"
SSH_EXTRA_OPTS=""
LOCAL_PORT="3000"
REMOTE_PORT="8080"
LLM_API_BASE_URL="https://api.openai.com/v1"
OPEN_WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
WEBUI_NAME=""
DEFAULT_MODELS=""
RAG_EMBEDDING_MODEL=""
HEALTH_TIMEOUT="300"
EC2_HOST=""
SSH_KEY_PATH=""
LLM_API_KEY=""

# shellcheck disable=SC1090
source "$CONFIG_FILE"

missing=()
for key in EC2_HOST SSH_KEY_PATH LLM_API_KEY; do
  [[ -n "${!key}" ]] || missing+=("$key")
done
[[ ${#missing[@]} -eq 0 ]] || die "missing required config keys in $CONFIG_FILE: ${missing[*]}" 2

SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
[[ -r "$SSH_KEY_PATH" ]] || die "SSH key not readable: $SSH_KEY_PATH" 2
[[ "$LOCAL_PORT" =~ ^[0-9]+$ && "$REMOTE_PORT" =~ ^[0-9]+$ && "$SSH_PORT" =~ ^[0-9]+$ ]] \
  || die "LOCAL_PORT, REMOTE_PORT and SSH_PORT must be numeric" 2

TARGET="${EC2_USER}@${EC2_HOST}"
URL="http://127.0.0.1:${LOCAL_PORT}/"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/open-webui-deploy"
mkdir -p "$STATE_DIR"
# Short, deterministic socket name: unix socket paths are limited to ~100 chars.
CTL_SOCK="${STATE_DIR}/t-$(printf '%s' "${TARGET}:${SSH_PORT}:${LOCAL_PORT}" | cksum | cut -d' ' -f1).sock"

SSH_OPTS=(
  -i "$SSH_KEY_PATH"
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -o BatchMode=yes
  -o ServerAliveInterval=30
)
if [[ -n "$SSH_EXTRA_OPTS" ]]; then
  read -r -a extra_opts <<<"$SSH_EXTRA_OPTS"
  SSH_OPTS+=("${extra_opts[@]}")
fi

# ---------------------------------------------------------------------------
# remote payload (runs under `bash -s` on the instance)
# ---------------------------------------------------------------------------
remote_env() {
  local v
  for v in REMOTE_PORT OPEN_WEBUI_IMAGE LLM_API_BASE_URL LLM_API_KEY WEBUI_NAME DEFAULT_MODELS RAG_EMBEDDING_MODEL; do
    printf 'export %s=%q\n' "$v" "${!v}"
  done
}

remote_payload() {
  cat <<'REMOTE'
set -euo pipefail
log() { printf '    [remote] %s\n' "$*"; }

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
APP_DIR="$HOME/open-webui"
ENV_FILE="$APP_DIR/.env"
CONTAINER="open-webui"
mkdir -p "$APP_DIR"

install_docker() {
  . /etc/os-release
  log "installing Docker on ${PRETTY_NAME:-$ID}"
  case "${ID}:${VERSION_ID:-}" in
    amzn:2023*)        $SUDO dnf install -y -q docker ;;
    amzn:2)            $SUDO amazon-linux-extras install -y docker ;;
    ubuntu:*|debian:*) curl -fsSL https://get.docker.com | $SUDO sh ;;
    *) echo "unsupported distro: ${PRETTY_NAME:-$ID}. Install Docker manually and re-run." >&2; exit 3 ;;
  esac
}

if ! command -v docker >/dev/null 2>&1; then
  install_docker
fi
if ! $SUDO systemctl is-active --quiet docker; then
  log "starting Docker daemon"
  $SUDO systemctl enable --now docker
fi
DOCKER="$SUDO docker"

# Preserve the session secret across re-deploys so existing logins stay valid.
SECRET=""
if [ -f "$ENV_FILE" ]; then
  SECRET="$(sed -n 's/^WEBUI_SECRET_KEY=//p' "$ENV_FILE" | head -n1)"
fi
if [ -z "$SECRET" ]; then
  if command -v openssl >/dev/null 2>&1; then
    SECRET="$(openssl rand -hex 32)"
  else
    SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi

umask 077
{
  echo "OPENAI_API_BASE_URL=${LLM_API_BASE_URL}"
  echo "OPENAI_API_KEY=${LLM_API_KEY}"
  echo "WEBUI_SECRET_KEY=${SECRET}"
  echo "ENABLE_OLLAMA_API=false"
  # Without this Open WebUI keeps the connection settings it stored on first boot
  # and silently ignores later changes to OPENAI_API_BASE_URL / OPENAI_API_KEY.
  echo "ENABLE_PERSISTENT_CONFIG=false"
  if [ -n "${WEBUI_NAME}" ]; then echo "WEBUI_NAME=${WEBUI_NAME}"; fi
  if [ -n "${DEFAULT_MODELS}" ]; then echo "DEFAULT_MODELS=${DEFAULT_MODELS}"; fi
  case "$OPEN_WEBUI_IMAGE" in
    *slim*)
      # slim images ship no local embedding / whisper models; route both to the API.
      echo "RAG_EMBEDDING_ENGINE=openai"
      echo "AUDIO_STT_ENGINE=openai"
      ;;
  esac
  if [ -n "${RAG_EMBEDDING_MODEL}" ]; then echo "RAG_EMBEDDING_MODEL=${RAG_EMBEDDING_MODEL}"; fi
} >"$ENV_FILE.tmp"
mv -f "$ENV_FILE.tmp" "$ENV_FILE"
log "wrote $ENV_FILE"

# Disk pre-flight: the full image unpacks to ~5 GB, slim to ~1 GB. Fail before pulling.
case "$OPEN_WEBUI_IMAGE" in *slim*) NEED_GB=2 ;; *) NEED_GB=6 ;; esac
DOCKER_ROOT="$($DOCKER info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
AVAIL_GB="$(df -BG --output=avail "$DOCKER_ROOT" | tail -n1 | tr -dc '0-9')"
if [ "${AVAIL_GB:-0}" -lt "$NEED_GB" ]; then
  echo "not enough disk for ${OPEN_WEBUI_IMAGE}: ${AVAIL_GB} GB free under ${DOCKER_ROOT}, need about ${NEED_GB} GB." >&2
  echo "Grow the root EBS volume, or set OPEN_WEBUI_IMAGE=ghcr.io/open-webui/open-webui:main-slim in deploy.conf." >&2
  exit 4
fi

log "pulling ${OPEN_WEBUI_IMAGE} (first time can take several minutes)"
$DOCKER pull -q "$OPEN_WEBUI_IMAGE"

if $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
  log "replacing existing container"
  $DOCKER rm -f "$CONTAINER" >/dev/null
fi

$DOCKER run -d --name "$CONTAINER" \
  --restart unless-stopped \
  -p "127.0.0.1:${REMOTE_PORT}:8080" \
  -v open-webui:/app/backend/data \
  --env-file "$ENV_FILE" \
  "$OPEN_WEBUI_IMAGE" >/dev/null

log "container started, listening on 127.0.0.1:${REMOTE_PORT} (instance-local only)"
REMOTE
}

run_remote() {
  # $1: a bash script to run remotely; config is prepended as exports so secrets
  # travel over stdin instead of the remote command line.
  { remote_env; printf '%s\n' "$1"; } | ssh "${SSH_OPTS[@]}" "$TARGET" bash -s
}

# ---------------------------------------------------------------------------
# tunnel management (ssh ControlMaster socket)
# ---------------------------------------------------------------------------
tunnel_is_up() { ssh -S "$CTL_SOCK" -O check "$TARGET" >/dev/null 2>&1; }

open_tunnel() {
  if tunnel_is_up; then
    log "tunnel already up on ${URL}"
    return 0
  fi
  rm -f "$CTL_SOCK"
  log "opening tunnel 127.0.0.1:${LOCAL_PORT} -> ${EC2_HOST}:${REMOTE_PORT}"
  if ! ssh "${SSH_OPTS[@]}" -f -N -M -S "$CTL_SOCK" \
        -o ExitOnForwardFailure=yes \
        -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "$TARGET"; then
    die "could not open tunnel. Is local port ${LOCAL_PORT} already in use? (lsof -i :${LOCAL_PORT})"
  fi
}

close_tunnel() {
  if tunnel_is_up; then
    ssh -S "$CTL_SOCK" -O exit "$TARGET" >/dev/null 2>&1 || true
    log "tunnel closed"
  else
    log "no tunnel running"
  fi
  rm -f "$CTL_SOCK"
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  log "waiting for Open WebUI to become healthy (timeout ${HEALTH_TIMEOUT}s)"
  until curl -fsS -o /dev/null --max-time 5 "${URL}health" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    printf '.'
    sleep 3
  done
  printf '\n'
}

open_browser() {
  [[ "$NO_BROWSER" -eq 0 ]] || { log "open ${URL} in your browser"; return 0; }
  if command -v open >/dev/null 2>&1; then
    open "$URL"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 &
  elif command -v start >/dev/null 2>&1; then          # Windows (Git Bash)
    start "$URL" >/dev/null 2>&1 &
  elif command -v cmd.exe >/dev/null 2>&1; then        # Windows (WSL / minimal)
    cmd.exe /c start "" "$URL" >/dev/null 2>&1 &
  else
    log "open ${URL} in your browser"
  fi
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd_deploy() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "# would run on ${TARGET}:  ssh ${SSH_OPTS[*]} ${TARGET} bash -s <<'EOF'"
    remote_env | sed -E 's/^(export LLM_API_KEY=).*/\1<masked>/'
    remote_payload
    echo "EOF"
    echo "# then: ssh ${SSH_OPTS[*]} -f -N -M -S ${CTL_SOCK} -o ExitOnForwardFailure=yes -L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT} ${TARGET}"
    echo "# then: wait for ${URL}health and open ${URL}"
    return 0
  fi

  log "deploying Open WebUI to ${TARGET}"
  run_remote "$(remote_payload)"
  open_tunnel
  if wait_healthy; then
    log "Open WebUI is up at ${URL}"
    open_browser
  else
    warn "Open WebUI did not answer within ${HEALTH_TIMEOUT}s. The tunnel is still up."
    warn "Check logs with:  $(basename "$0") logs -c ${CONFIG_FILE}"
    exit 1
  fi
}

cmd_tunnel() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "ssh ${SSH_OPTS[*]} -f -N -M -S ${CTL_SOCK} -o ExitOnForwardFailure=yes -L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT} ${TARGET}"
    return 0
  fi
  open_tunnel
  if wait_healthy; then
    log "Open WebUI is up at ${URL}"
    open_browser
  else
    warn "tunnel is up but ${URL}health is not answering. Is the container running? Try: $(basename "$0") status"
    exit 1
  fi
}

cmd_status() {
  if tunnel_is_up; then
    echo "tunnel:    up  (${URL})"
  else
    echo "tunnel:    down"
  fi
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  echo "container:"
  run_remote '
    SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
    if ! command -v docker >/dev/null 2>&1; then echo "    docker not installed"; exit 0; fi
    out="$($SUDO docker ps -a --filter name=^open-webui$ --format "    {{.Status}}  image={{.Image}}  ports={{.Ports}}")"
    if [ -n "$out" ]; then echo "$out"; else echo "    not deployed"; fi
  '
}

cmd_logs() {
  [[ "$DRY_RUN" -eq 0 ]] || { echo "ssh ${SSH_OPTS[*]} ${TARGET} sudo docker logs --tail 200 -f open-webui"; return 0; }
  ssh "${SSH_OPTS[@]}" -t "$TARGET" 'SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"; $SUDO docker logs --tail 200 -f open-webui'
}

cmd_down() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "ssh -S ${CTL_SOCK} -O exit ${TARGET}"
    [[ "$DOWN_REMOTE" -eq 0 ]] || echo "ssh ${SSH_OPTS[*]} ${TARGET} sudo docker rm -f open-webui"
    return 0
  fi
  close_tunnel
  if [[ "$DOWN_REMOTE" -eq 1 ]]; then
    log "removing container on ${TARGET} (data volume 'open-webui' is kept)"
    run_remote '
      SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
      if command -v docker >/dev/null 2>&1 && $SUDO docker inspect open-webui >/dev/null 2>&1; then
        $SUDO docker rm -f open-webui >/dev/null && echo "    [remote] container removed"
      else
        echo "    [remote] no container to remove"
      fi
    '
  fi
}

case "$COMMAND" in
  deploy) cmd_deploy ;;
  tunnel) cmd_tunnel ;;
  status) cmd_status ;;
  logs)   cmd_logs ;;
  down)   cmd_down ;;
esac
