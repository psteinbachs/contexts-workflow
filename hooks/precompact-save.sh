#!/bin/bash
# PreCompact hook - fires when Claude Code is about to compact context
# This is the RIGHT time to save - Claude has decided context is full

set -euo pipefail

CONTEXTS_URL="${CONTEXTS_URL:-http://localhost:8100}"

# Shared env detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env-detect.sh"

# Read hook input from stdin
INPUT=$(cat)

# Extract session info
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Determine environment
ENV=$(detect_env "$CWD")

# Read recent transcript for context extraction (last 100KB)
TRANSCRIPT_CONTENT=""
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    TRANSCRIPT_CONTENT=$(tail -c 102400 "$TRANSCRIPT_PATH" 2>/dev/null | jq -Rs . 2>/dev/null || echo '""')
fi

# Save session - we KNOW context is full because PreCompact fired
PAYLOAD=$(jq -n \
    --arg env "$ENV" \
    --argjson tokens 200000 \
    --argjson max_tokens 200000 \
    --argjson transcript "$TRANSCRIPT_CONTENT" \
    '{
        environment: $env,
        used_tokens: $tokens,
        max_tokens: $max_tokens,
        transcript_content: $transcript
    }')

SAVE_RESPONSE=$(curl -s -X POST "${CONTEXTS_URL}/context/auto-save" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null || echo '{}')

SAVE_STATUS=$(echo "$SAVE_RESPONSE" | jq -r '.status // "failed"')
EXTRACTED_TASK=$(echo "$SAVE_RESPONSE" | jq -r '.task // "unknown"' | head -c 80)

if [[ "$SAVE_STATUS" == "saved" ]]; then
    echo ""
    echo "=================================================="
    echo "CONTEXT COMPACTING - Session auto-saved"
    echo "Task: ${EXTRACTED_TASK}..."
    echo ""
    echo "After compaction, run 'rs $ENV' to restore context"
    echo "=================================================="
fi

exit 0
