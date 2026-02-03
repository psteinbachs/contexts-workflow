#!/bin/bash
# Claude Code status line - Dynamic from contexts-mcp
# Fetches environment colors from API, caches locally

CACHE_FILE=~/.claude/statusline-cache.json
CACHE_TTL=300  # 5 minutes
CONTEXTS_URL="${CONTEXTS_URL:-http://localhost:8100}"
API_URL="${CONTEXTS_URL}/env"

input=$(cat)

# Extract values from JSON input
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // "?"')
CONTEXT_PCT=$(echo "$input" | jq -r '.context.used_percent // 0' | cut -d. -f1)

# Shorten model name
case "$MODEL" in
  *Opus*)   MODEL="opus" ;;
  *Sonnet*) MODEL="sonnet" ;;
  *Haiku*)  MODEL="haiku" ;;
esac

# Shared env detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env-detect.sh"

ENV=$(detect_env "$DIR")

# Refresh cache if stale or missing
refresh_cache() {
  local data
  data=$(curl -sf --connect-timeout 1 "$API_URL" 2>/dev/null)
  if [ -n "$data" ]; then
    echo "$data" > "$CACHE_FILE"
  fi
}

# Check cache age
if [ -f "$CACHE_FILE" ]; then
  cache_age=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))
  [ "$cache_age" -gt "$CACHE_TTL" ] && refresh_cache
else
  refresh_cache
fi

# Get statusline config for current env from cache
if [ -f "$CACHE_FILE" ] && [ "$ENV" != "?" ]; then
  BG_RGB=$(jq -r --arg env "$ENV" '.statusline[$env].bg_rgb // empty' "$CACHE_FILE" 2>/dev/null)
  ICON=$(jq -r --arg env "$ENV" '.statusline[$env].icon // empty' "$CACHE_FILE" 2>/dev/null)
fi

# Defaults if not found
[ -z "$BG_RGB" ] && BG_RGB="46;52;64"  # Nordic dark
[ -z "$ICON" ] && ICON=""

# True color escape sequences
C_RESET="\e[0m"

# Nordic palette for fixed segments
C_BG2="48;2;59;66;82"    # #3b4252
C_FG2="38;2;59;66;82"
C_BG3="48;2;67;76;94"    # #434c5e
C_FG3="38;2;67;76;94"
C_BG6="48;2;98;114;164"  # #6272a4
C_FG6="38;2;98;114;164"

# Dynamic env segment color
C_BG_ENV="48;2;${BG_RGB}"
C_FG_ENV="38;2;${BG_RGB}"

# Build powerline segments
SEG1="\e[${C_BG_ENV};37m ${ICON} ${ENV} \e[${C_FG_ENV};${C_BG2}m"
SEG2="\e[${C_BG2};37m ${MODEL} \e[${C_FG2};${C_BG3}m"
SEG3="\e[${C_BG3};37m ctx:${CONTEXT_PCT}% \e[${C_FG3};${C_BG6}m"

BASENAME="${DIR##*/}"
SEG4="\e[${C_BG6};37m  ${BASENAME} \e[${C_FG6}m"

echo -e "${SEG1}${SEG2}${SEG3}${SEG4}${C_RESET}"
