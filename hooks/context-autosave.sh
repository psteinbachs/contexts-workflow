#!/bin/bash
# Context auto-save hook - runs on PostToolUse
# Automatically saves session when context hits critical threshold
# Only saves once per session to avoid spam

set -euo pipefail

CONTEXTS_URL="${CONTEXTS_URL:-http://localhost:8100}"
MAX_TOKENS=200000
CRITICAL_THRESHOLD=85  # Save at 85%

# Shared env detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env-detect.sh"

# Read hook input from stdin
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Skip if no session ID
[[ -z "$SESSION_ID" ]] && exit 0

# Check if we already saved this session (marker file)
MARKER_FILE="/tmp/.claude-autosave-${SESSION_ID}"
[[ -f "$MARKER_FILE" ]] && exit 0

# Determine environment
ENV=$(detect_env "$CWD")

# Estimate tokens from transcript
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    # Parse JSONL: sum content lengths, divide by ~4 chars/token
    ESTIMATED_TOKENS=$(tail -c 3145728 "$TRANSCRIPT_PATH" 2>/dev/null | \
        jq -r '
            .content |
            if type == "array" then
                map(if type == "object" then .text // "" else . end) | join("") | length
            elif type == "string" then length
            else 0 end
        ' 2>/dev/null | \
        awk '{sum += $1} END {print int(sum/4)}' || echo "0")

    # Fallback
    if [[ -z "$ESTIMATED_TOKENS" || "$ESTIMATED_TOKENS" == "0" ]]; then
        RECENT_LINES=$(tail -c 2097152 "$TRANSCRIPT_PATH" 2>/dev/null | wc -l || echo "0")
        ESTIMATED_TOKENS=$((RECENT_LINES * 50))
    fi

    # Cap at max
    [[ $ESTIMATED_TOKENS -gt $MAX_TOKENS ]] && ESTIMATED_TOKENS=$MAX_TOKENS
else
    exit 0
fi

# Calculate percentage
PERCENT=$((ESTIMATED_TOKENS * 100 / MAX_TOKENS))

# Only act if we hit critical threshold
[[ $PERCENT -lt $CRITICAL_THRESHOLD ]] && exit 0

# Mark this session as saved (prevent repeated saves)
touch "$MARKER_FILE"

# Read transcript content for context extraction
TRANSCRIPT_CONTENT=$(tail -c 102400 "$TRANSCRIPT_PATH" 2>/dev/null | jq -Rs . 2>/dev/null || echo '""')

# Auto-save
PAYLOAD=$(jq -n \
    --arg env "$ENV" \
    --argjson tokens "$ESTIMATED_TOKENS" \
    --argjson max_tokens "$MAX_TOKENS" \
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

if [[ "$SAVE_STATUS" == "saved" ]]; then
    echo ""
    echo "=============================================="
    echo "CONTEXT ${PERCENT}% - Session auto-saved"
    echo "Run /clear to reset context (auto-restores)"
    echo "=============================================="
fi

exit 0
