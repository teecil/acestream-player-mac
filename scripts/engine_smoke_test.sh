#!/bin/bash
# Checks the engine pipeline on this Mac without the GUI:
#   Docker → ARM64 engine image → engine API → (optional) a real stream.
# Usage: scripts/engine_smoke_test.sh [acestream-content-id]
set -uo pipefail

IMAGE="${IMAGE:-jopsis/acestream@sha256:39d90d2c4b069108e4958a3c997bc8558e9b649c0dfdf23bc0e8854bedfb491f}"
PLATFORM="${PLATFORM:-linux/arm64}"
PORT="${PORT:-16899}"
NAME="acestream-player-smoketest"
ID="${1:-}"
DOCKER="/Applications/Docker.app/Contents/Resources/bin/docker"
[ -x "$DOCKER" ] || DOCKER="$(command -v docker)"
[ -S "$HOME/.docker/run/docker.sock" ] && export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"

pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; exit 1; }

echo "1. Docker engine"
"$DOCKER" info --format '{{.ServerVersion}} ({{.Architecture}})' 2>/dev/null && pass "Docker answers" || fail "Docker is not running"

echo "2. Engine image $IMAGE [$PLATFORM]"
"$DOCKER" pull --platform "$PLATFORM" "$IMAGE" >/dev/null && pass "image present" || fail "pull failed"
ARCH=$("$DOCKER" image inspect --format '{{.Architecture}}' "$IMAGE")
echo "     image architecture: $ARCH"

echo "3. Start engine on 127.0.0.1:$PORT"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --name "$NAME" --platform "$PLATFORM" -p "127.0.0.1:$PORT:6878" "$IMAGE" >/dev/null || fail "docker run failed"
for i in $(seq 1 90); do
  if OUT=$(curl -fsS -m 3 "http://127.0.0.1:$PORT/webui/api/service?method=get_version" 2>/dev/null); then
    pass "engine ready after ${i}s: $OUT"; break
  fi
  sleep 1
  [ "$i" = 90 ] && { "$DOCKER" logs --tail 30 "$NAME"; fail "engine did not answer in 90s"; }
done

if [ -n "$ID" ]; then
  echo "4. Open stream $ID"
  JSON=$(curl -fsS -m 60 "http://127.0.0.1:$PORT/ace/getstream?format=json&id=$ID") || fail "getstream failed"
  echo "     $JSON"
  STAT=$(echo "$JSON" | sed -nE 's/.*"stat_url": *"([^"]+)".*/\1/p')
  [ -n "$STAT" ] || fail "no stat_url in response"
  STAT="http://127.0.0.1:$PORT$(echo "$STAT" | sed -E 's#^https?://[^/]+##')"
  for i in $(seq 1 60); do
    S=$(curl -fsS -m 5 "$STAT" 2>/dev/null)
    echo "     [$i] $S" | cut -c1-160
    echo "$S" | grep -q '"status": *"dl"' && { pass "stream is downloading"; break; }
    sleep 1
  done
fi

"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
pass "cleaned up"
