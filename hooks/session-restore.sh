#!/bin/bash
# SessionStart hook - auto-restore context after /clear or compaction
# Matcher: clear|compact

set -euo pipefail

CONTEXTS_URL="${CONTEXTS_URL:-http://localhost:8100}"

# Shared env detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env-detect.sh"

# Read hook input
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only run on clear or compact events
[[ "$SOURCE" != "clear" && "$SOURCE" != "compact" ]] && exit 0

# Determine environment
ENV=$(detect_env "$CWD")

# Fetch last session from qdrant
RESPONSE=$(curl -s -X POST "${CONTEXTS_URL}/rs" \
    -H "Content-Type: application/json" \
    -d "{\"environment\": \"$ENV\", \"limit\": 1}" 2>/dev/null || echo '{}')

# Extract session info
TASK=$(echo "$RESPONSE" | jq -r '.sessions[0].task // "No previous session"')
CONTEXT=$(echo "$RESPONSE" | jq -r '.sessions[0].context // ""')
NEXT_STEPS=$(echo "$RESPONSE" | jq -r '.sessions[0].next_steps // ""')
KEY_ARTIFACTS=$(echo "$RESPONSE" | jq -r '.sessions[0].key_artifacts // [] | join(", ")')

# Build context for Claude
RESTORE_CONTEXT="## Session Restored (${ENV})

**Previous task:** ${TASK}

**Context:** ${CONTEXT}

**Next steps:** ${NEXT_STEPS}"

if [[ -n "$KEY_ARTIFACTS" ]]; then
    RESTORE_CONTEXT="${RESTORE_CONTEXT}

**Key artifacts to review:** ${KEY_ARTIFACTS}"
fi

# Output as additionalContext via JSON
jq -n --arg ctx "$RESTORE_CONTEXT" '{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": $ctx
    }
}'

exit 0
