#!/bin/bash
# OpenCUA install script — builds the helper, installs everything into
# ~/.opencua (helper app + CLI), and prints MCP registration snippets for
# common agents.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME/.opencua"
BIN_DIR="$HOME_DIR/bin"

echo "==> Building..."
bash "$ROOT/scripts/build.sh"

echo "==> Installing to $HOME_DIR ..."
mkdir -p "$BIN_DIR"
rm -rf "$BIN_DIR/OpenCUA Helper.app"
cp -R "$ROOT/dist/OpenCUA Helper.app" "$BIN_DIR/"
chmod +x "$ROOT/server/cua.mjs" "$ROOT/server/opencua-mcp.mjs" 2>/dev/null || true
ln -sf "$ROOT/server/cua.mjs" "$BIN_DIR/cua" 2>/dev/null || true

echo "==> Starting helper (will request permissions on first run)..."
pkill -f "opencua-helper" 2>/dev/null || true
sleep 0.5
open -g "$BIN_DIR/OpenCUA Helper.app"
sleep 2

echo "==> Checking permissions..."
PERMS=$(node "$ROOT/server/cua.mjs" doctor 2>/dev/null || true)
if echo "$PERMS" | grep -q '"all_granted": true'; then
    echo "    ✓ Permissions OK"
else
    echo "    ⚠ Permissions incomplete. Opening System Settings..."
    echo "    Grant Accessibility + Screen Recording to 'OpenCUA Helper', then re-run doctor."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
    echo ""
    echo "    After granting, verify with:"
    echo "      node \"$ROOT/server/cua.mjs\" doctor"
fi

echo ""
echo "==> Done. MCP registration snippets:"
echo ""
echo "   Claude Code:"
echo "     claude mcp add opencua -- node \"$ROOT/server/opencua-mcp.mjs\""
echo ""
echo "   Cursor / Cline / WorkBuddy / generic MCP JSON:"
echo "     { \"mcpServers\": { \"opencua\": { \"type\": \"stdio\", \"command\": \"$(command -v node)\", \"args\": [\"$ROOT/server/opencua-mcp.mjs\"] } } }"
echo ""
echo "CLI usage: node $ROOT/server/cua.mjs <doctor|apps|state|shot|click|type|key|scroll|drag|open|openurl|policy|start|stop>"
echo ""
echo "Config (~/.opencua/config.json):"
echo "  auto_approve (bool, default true)  — allow unknown apps without interactive approval"
echo "  cursor (bool, default true)        — show glide cursor animation"
echo "  allow/deny (string arrays)         — per-app allowlist/denylist"
echo ""
echo "Env vars:"
echo "  OPENCUA_AUTO_APPROVE=0  — disable auto-approve (require per-app approval)"
echo "  OPENCUA_CURSOR=0        — disable glide cursor"
echo "  OPENCUA_EXIT_GRACE=20   — seconds to live after the last client leaves (0 = exit now, negative = never)"
echo "  OPENCUA_IDLE_TIMEOUT=900— seconds of inactivity before exiting even if a client stays connected (0 = off)"
echo "  OPENCUA_KEEP_ALIVE=1    — never auto-exit (helper stays resident)"
echo ""
echo "Lifetime: the helper is NOT a daemon — it exits by itself right after the work"
echo "is done and is restarted lazily on the next call. Stop it now with:"
echo "  node \"$ROOT/server/cua.mjs\" stop"
