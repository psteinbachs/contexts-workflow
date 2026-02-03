#!/bin/bash
# Context monitor hook for Claude Code
# Runs on Stop event to check context usage and auto-save if needed

set -euo pipefail

CONTEXTS_URL="${CONTEXTS_URL:-http://localhost:8100}"
MAX_TOKENS=200000

# Shared env detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env-detect.sh"

# Read hook input from stdin
INPUT=$(cat)

# Check if Claude Code provides token count directly (preferred)
USED_TOKENS=$(echo "$INPUT" | jq -r '.token_count // .used_tokens // empty')

# Extract transcript path and session info
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Determine environment
ENV=$(detect_env "$CWD")

# If no direct token count, estimate by parsing JSONL transcript
if [[ -z "$USED_TOKENS" ]]; then
    if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
        # Parse JSONL: sum content lengths from recent messages, divide by ~4 chars/token
        # Only look at last 3MB to stay performant
        ESTIMATED_TOKENS=$(tail -c 3145728 "$TRANSCRIPT_PATH" 2>/dev/null | \
            jq -r '
                .content |
                if type == "array" then
                    map(if type == "object" then .text // "" else . end) | join("") | length
                elif type == "string" then length
                else 0 end
            ' 2>/dev/null | \
            awk '{sum += $1} END {print int(sum/4)}' || echo "0")

        # Fallback if jq parsing fails
        if [[ -z "$ESTIMATED_TOKENS" || "$ESTIMATED_TOKENS" == "0" ]]; then
            RECENT_LINES=$(tail -c 2097152 "$TRANSCRIPT_PATH" 2>/dev/null | wc -l || echo "0")
            ESTIMATED_TOKENS=$((RECENT_LINES * 50))
        fi

        # Cap at max to avoid absurd percentages
        if [[ $ESTIMATED_TOKENS -gt $MAX_TOKENS ]]; then
            ESTIMATED_TOKENS=$MAX_TOKENS
        fi
    else
        exit 0
    fi
else
    ESTIMATED_TOKENS=$USED_TOKENS
fi

# Skip if estimate is too low (likely just started)
if [[ $ESTIMATED_TOKENS -lt 50000 ]]; then
    exit 0
fi

# Query context usage endpoint
RESPONSE=$(curl -s "${CONTEXTS_URL}/context/usage?used_tokens=${ESTIMATED_TOKENS}&max_tokens=${MAX_TOKENS}" 2>/dev/null || echo '{}')

# Sanity check: if we couldn't get a valid response, skip
if ! echo "$RESPONSE" | jq -e '.action' >/dev/null 2>&1; then
    exit 0
fi

ACTION_TYPE=$(echo "$RESPONSE" | jq -r '.action.type // "none"')
PERCENT=$(echo "$RESPONSE" | jq -r '.percent // 0')

case "$ACTION_TYPE" in
    "save_and_restart")
        # Read transcript content (last 100KB to keep payload reasonable)
        TRANSCRIPT_CONTENT=""
        if [[ -f "$TRANSCRIPT_PATH" ]]; then
            # Get last 100KB of transcript, properly escaped for JSON
            TRANSCRIPT_CONTENT=$(tail -c 102400 "$TRANSCRIPT_PATH" 2>/dev/null | jq -Rs . 2>/dev/null || echo '""')
        fi

        # Build JSON payload with jq to ensure proper escaping
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

        # Auto-save the session with transcript content
        SAVE_RESPONSE=$(curl -s -X POST "${CONTEXTS_URL}/context/auto-save" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" 2>/dev/null || echo '{}')

        SAVE_STATUS=$(echo "$SAVE_RESPONSE" | jq -r '.status // "failed"')
        EXTRACTED_TASK=$(echo "$SAVE_RESPONSE" | jq -r '.task // "unknown"' | head -c 80)

        if [[ "$SAVE_STATUS" == "saved" ]]; then
            echo ""
            echo "=================================================="
            echo "CONTEXT CRITICAL: ${PERCENT}% used (~${ESTIMATED_TOKENS} tokens)"
            echo "Session auto-saved to Qdrant."
            echo "Task: ${EXTRACTED_TASK}..."
            echo ""
            echo "Recommended: Start fresh session with 'rs $ENV'"
            echo "=================================================="
        fi
        ;;

    "save")
        echo ""
        echo "Context at ${PERCENT}% (~${ESTIMATED_TOKENS} tokens). Consider: ss"
        ;;
esac

exit 0
