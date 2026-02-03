#!/bin/bash
# Dynamic MCP connection wrapper
# Reads current environment token and connects to contexts-mcp

ENV_DIR="$HOME/.claude/env"
CONTEXTS_URL="${CONTEXTS_URL:-http://localhost:8100}"

# Shared env detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env-detect.sh"

# Detect environment
CURRENT_ENV=$(detect_env "$(pwd)")

# Read token for current environment
TOKEN_FILE="$ENV_DIR/${CURRENT_ENV}.session-token"
if [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE")
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        URL="${CONTEXTS_URL}/mcp/sse?token=${TOKEN}"
    else
        URL="${CONTEXTS_URL}/mcp/sse"
    fi
else
    URL="${CONTEXTS_URL}/mcp/sse"
fi

exec npx -y mcp-remote "$URL" --allow-http
