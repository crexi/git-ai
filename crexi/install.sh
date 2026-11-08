#!/usr/bin/env bash
# Install or upgrade to the Crexi build of git-ai (configurable metrics retention).
#
# Downloads the right binary from the crexi/git-ai GitHub releases, verifies its
# checksum, swaps it into ~/.git-ai/bin, turns off auto-updates, sets the
# transcript-event retention, and restarts the daemon.
#
# Usage:  install.sh [--shrink] [--tag vX.Y.Z-crexi.N]
#   --shrink   also delete transcript events older than the retention window and
#              VACUUM the metrics database (needs sqlite3; reclaims disk now)
#   --tag      install a specific release instead of the latest
# Env:    GIT_AI_SESSION_EVENT_RETENTION_DAYS (default 7)
#
# First-time git-ai users: run the upstream installer first so hooks and PATH get
# set up (https://usegitai.com), then run this to swap in the Crexi build.
set -euo pipefail

REPO="${GIT_AI_CREXI_REPO:-crexi/git-ai}"
TAG=""
RETENTION_DAYS="${GIT_AI_SESSION_EVENT_RETENTION_DAYS:-7}"
SHRINK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shrink) SHRINK=1 ;;
    --tag) TAG="$2"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"

daemon_running() { "$1" bg status 2>/dev/null | grep -q '"daemon_running": true'; }
# wait_daemon <binary> running|stopped <seconds>
wait_daemon() {
  local i
  for i in $(seq 1 "$3"); do
    if daemon_running "$1"; then [ "$2" = running ] && return 0; else [ "$2" = stopped ] && return 0; fi
    sleep 1
  done
  return 1
}

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS/$ARCH" in
  linux/x86_64)              ASSET=git-ai-linux-x64 ;;
  linux/aarch64|linux/arm64) ASSET=git-ai-linux-arm64 ;;
  darwin/arm64)              ASSET=git-ai-macos-arm64 ;;
  darwin/x86_64)             ASSET=git-ai-macos-x64 ;;
  *) die "unsupported platform $OS/$ARCH (Windows: use install.ps1)" ;;
esac

if [ -n "$TAG" ]; then BASE="https://github.com/$REPO/releases/download/$TAG"
else BASE="https://github.com/$REPO/releases/latest/download"; fi

INSTALL_DIR="$HOME/.git-ai/bin"
BIN="$INSTALL_DIR/git-ai"
mkdir -p "$INSTALL_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading $ASSET from $REPO ${TAG:-(latest)}"
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS"
(
  cd "$TMP"
  if command -v sha256sum >/dev/null; then grep " $ASSET\$" SHA256SUMS | sha256sum -c - >/dev/null
  else grep " $ASSET\$" SHA256SUMS | shasum -a 256 -c - >/dev/null; fi
) || die "checksum mismatch for $ASSET"

FRESH=1
if [ -x "$BIN" ]; then
  FRESH=0
  say "Stopping the running daemon ($("$BIN" --version 2>/dev/null || echo unknown))"
  "$BIN" bg shutdown >/dev/null 2>&1 || true
  wait_daemon "$BIN" stopped 20 || say "warning: daemon still running; continuing"
  cp -p "$BIN" "$BIN.bak-$(date +%Y%m%d%H%M%S)"
fi

install -m 0755 "$TMP/$ASSET" "$BIN"
if [ "$OS" = darwin ]; then xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true; fi
if mkdir -p "$HOME/.local/bin" 2>/dev/null; then ln -sf "$BIN" "$HOME/.local/bin/git-ai" 2>/dev/null || true; fi

"$BIN" config set disable_auto_updates true >/dev/null
"$BIN" config set session_event_retention_days "$RETENTION_DAYS" >/dev/null

if [ "$FRESH" = 1 ]; then
  say "Fresh install: setting up editor hooks and PATH"
  "$BIN" install-hooks --env || say "warning: install-hooks failed; run '$BIN install-hooks --env' manually"
fi

if [ "$SHRINK" = 1 ]; then
  DB="$HOME/.git-ai/internal/metrics-db"
  if [ -f "$DB" ] && command -v sqlite3 >/dev/null; then
    say "Deleting transcript events older than $RETENTION_DAYS days and compacting $DB"
    sqlite3 "$DB" "PRAGMA busy_timeout=600000; DELETE FROM metrics WHERE event_kind=5 AND event_ts < strftime('%s','now')-$RETENTION_DAYS*86400; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);"
  else
    say "skipping --shrink: metrics-db or sqlite3 not found"
  fi
fi

"$BIN" bg start >/dev/null 2>&1 || true
if wait_daemon "$BIN" running 15; then say "Daemon running"
else say "note: daemon not running yet; it starts automatically on the next git command"; fi
say "Installed $("$BIN" --version) at $BIN"
say "session_event_retention_days = $("$BIN" config session_event_retention_days)"
if [ -f "$HOME/.git-ai/internal/metrics-db" ]; then say "metrics-db: $(du -h "$HOME/.git-ai/internal/metrics-db" | cut -f1)"; fi
