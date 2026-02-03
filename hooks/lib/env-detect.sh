#!/bin/bash
# Shared environment detection library
# Source this file, then call: detect_env "$CWD"
#
# Detection priority:
#   1. Statusline env file (TTY-scoped)
#   2. CWD map file (~/.claude/env/cwd-map.conf)
#   3. CONTEXTS_DEFAULT_ENV environment variable
#   4. Fallback: "dev"

detect_env() {
    local cwd="${1:-$(pwd)}"

    # 1. Check TTY-scoped statusline file
    local tty_id
    tty_id=$(pid=$$; while [ "$pid" != "1" ]; do
        t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' ')
        [ -n "$t" ] && [ "$t" != "?" ] && echo "$t" | tr '/' '-' && break
        pid=$(ps -o ppid= -p $pid 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] && break
    done)

    local env_file="/tmp/${HOSTNAME}-claude-env-${tty_id}"
    if [[ -f "$env_file" ]]; then
        cat "$env_file"
        return 0
    fi

    # 2. Check CWD map file (pattern=env per line)
    local cwd_map="$HOME/.claude/env/cwd-map.conf"
    if [[ -f "$cwd_map" ]]; then
        while IFS='=' read -r pattern env_name; do
            # Skip comments and empty lines
            [[ "$pattern" =~ ^#.*$ || -z "$pattern" ]] && continue
            if [[ "$cwd" == *"$pattern"* ]]; then
                echo "$env_name"
                return 0
            fi
        done < "$cwd_map"
    fi

    # 3. CONTEXTS_DEFAULT_ENV environment variable
    if [[ -n "${CONTEXTS_DEFAULT_ENV:-}" ]]; then
        echo "$CONTEXTS_DEFAULT_ENV"
        return 0
    fi

    # 4. Fallback
    echo "dev"
}
