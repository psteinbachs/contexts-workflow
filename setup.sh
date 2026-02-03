#!/bin/bash
# contexts-workflow installer
# Two modes: full install (new machine) or hooks-only (existing stack)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXTS_URL="${CONTEXTS_URL:-localhost:8100}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
ENV_DIR="$CLAUDE_DIR/env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*"; }

# --- Prerequisite checks ---

check_prereq() {
    if ! command -v "$1" &>/dev/null; then
        err "Required: $1 not found. $2"
        return 1
    fi
    ok "$1 found"
}

check_common_prereqs() {
    local ok=true
    check_prereq jq "Install: apt install jq / brew install jq" || ok=false
    check_prereq curl "Install: apt install curl / brew install curl" || ok=false
    check_prereq npx "Install: npm install -g npx (from Node.js)" || ok=false
    $ok || { err "Missing prerequisites. Install them and re-run."; exit 1; }
}

# --- URL substitution helper ---

substitute_url() {
    local file="$1"
    if [[ "$CONTEXTS_URL" != "localhost:8100" ]]; then
        sed -i "s|localhost:8100|${CONTEXTS_URL}|g" "$file"
    fi
}

# --- Hooks installation (shared by both flows) ---

install_hooks() {
    info "Installing hooks..."

    # Create directories
    mkdir -p "$HOOKS_DIR/lib" "$CLAUDE_DIR/lib" "$ENV_DIR"

    # Copy env-detect library
    cp "$SCRIPT_DIR/hooks/lib/env-detect.sh" "$HOOKS_DIR/lib/env-detect.sh"
    chmod +x "$HOOKS_DIR/lib/env-detect.sh"
    ok "env-detect.sh library"

    # Copy env-detect library to ~/.claude/lib (for statusline.sh)
    cp "$SCRIPT_DIR/hooks/lib/env-detect.sh" "$CLAUDE_DIR/lib/env-detect.sh"
    chmod +x "$CLAUDE_DIR/lib/env-detect.sh"

    # Copy hook scripts (backup existing)
    for hook in context-monitor.sh context-autosave.sh session-restore.sh precompact-save.sh; do
        if [[ -f "$HOOKS_DIR/$hook" ]]; then
            cp "$HOOKS_DIR/$hook" "$HOOKS_DIR/${hook}.bak.${TIMESTAMP}"
            warn "Backed up existing $hook"
        fi
        cp "$SCRIPT_DIR/hooks/$hook" "$HOOKS_DIR/$hook"
        chmod +x "$HOOKS_DIR/$hook"
        substitute_url "$HOOKS_DIR/$hook"
        ok "$hook"
    done

    # Copy mcp-connect.sh to ~/.claude/
    if [[ -f "$CLAUDE_DIR/mcp-connect.sh" ]]; then
        cp "$CLAUDE_DIR/mcp-connect.sh" "$CLAUDE_DIR/mcp-connect.sh.bak.${TIMESTAMP}"
        warn "Backed up existing mcp-connect.sh"
    fi
    cp "$SCRIPT_DIR/hooks/mcp-connect.sh" "$CLAUDE_DIR/mcp-connect.sh"
    chmod +x "$CLAUDE_DIR/mcp-connect.sh"
    substitute_url "$CLAUDE_DIR/mcp-connect.sh"
    ok "mcp-connect.sh"

    # Copy statusline.sh (optional)
    if [[ -f "$CLAUDE_DIR/statusline.sh" ]]; then
        cp "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh.bak.${TIMESTAMP}"
        warn "Backed up existing statusline.sh"
    fi
    cp "$SCRIPT_DIR/hooks/statusline.sh" "$CLAUDE_DIR/statusline.sh"
    chmod +x "$CLAUDE_DIR/statusline.sh"
    substitute_url "$CLAUDE_DIR/statusline.sh"
    ok "statusline.sh"

    # Copy contexts-workflow.md template
    if [[ -f "$CLAUDE_DIR/contexts-workflow.md" ]]; then
        cp "$CLAUDE_DIR/contexts-workflow.md" "$CLAUDE_DIR/contexts-workflow.md.bak.${TIMESTAMP}"
        warn "Backed up existing contexts-workflow.md"
    fi
    cp "$SCRIPT_DIR/templates/contexts-workflow.md" "$CLAUDE_DIR/contexts-workflow.md"
    substitute_url "$CLAUDE_DIR/contexts-workflow.md"
    ok "contexts-workflow.md"

    # Copy example env file if env dir is empty
    if [[ -z "$(ls -A "$ENV_DIR" 2>/dev/null)" ]]; then
        local env_name="${FIRST_ENV:-dev}"
        cp "$SCRIPT_DIR/templates/env/example.md" "$ENV_DIR/${env_name}.md"
        if [[ "$env_name" != "dev" ]]; then
            sed -i "s/# dev/# ${env_name}/g; s/environment=dev/environment=${env_name}/g" "$ENV_DIR/${env_name}.md"
        fi
        substitute_url "$ENV_DIR/${env_name}.md"
        ok "Created env file: ${env_name}.md"
    else
        info "Env dir not empty, skipping example env file"
    fi

    # Create cwd-map.conf if it doesn't exist
    if [[ ! -f "$ENV_DIR/cwd-map.conf" ]]; then
        cat > "$ENV_DIR/cwd-map.conf" <<'CWDMAP'
# CWD-to-environment mapping
# Format: pattern=environment
# The first matching pattern wins (substring match against cwd)
#
# Examples:
# /home/user/projects/myapp=dev
# /home/user/infra=prod
CWDMAP
        ok "Created cwd-map.conf template"
    fi

    # Merge settings.json
    info "Configuring Claude Code settings..."
    merge_settings

    # Add @contexts-workflow.md to CLAUDE.md
    inject_claude_md

    # Configure Zed if installed
    configure_zed
}

inject_claude_md() {
    local claude_md="$CLAUDE_DIR/CLAUDE.md"
    local include_line="@contexts-workflow.md"

    if [[ -f "$claude_md" ]]; then
        # Check if already included
        if grep -qF "$include_line" "$claude_md"; then
            info "CLAUDE.md already references contexts-workflow.md"
            return
        fi
        # Append to existing
        cp "$claude_md" "${claude_md}.bak.${TIMESTAMP}"
        warn "Backed up existing CLAUDE.md"
        printf '\n%s\n' "$include_line" >> "$claude_md"
        ok "Appended $include_line to CLAUDE.md"
    else
        # Create new
        echo "$include_line" > "$claude_md"
        ok "Created CLAUDE.md with $include_line"
    fi
}

merge_settings() {
    local settings_file="$CLAUDE_DIR/settings.json"
    local snippet_file="$SCRIPT_DIR/templates/settings-snippet.json"
    local actual_home
    actual_home=$(echo "$HOME" | sed 's/[\/&]/\\&/g')

    # Prepare snippet with actual $HOME path
    local prepared_snippet
    prepared_snippet=$(sed "s|\\\$HOME|${HOME}|g" "$snippet_file")

    if [[ -f "$settings_file" ]]; then
        # Backup existing
        cp "$settings_file" "${settings_file}.bak.${TIMESTAMP}"
        warn "Backed up existing settings.json"

        # Deep merge: snippet values override existing for hooks/mcpServers
        local merged
        merged=$(echo "$prepared_snippet" | jq -s '.[0] * .[1]' "$settings_file" - 2>/dev/null)

        if [[ -n "$merged" && "$merged" != "null" ]]; then
            echo "$merged" | jq '.' > "$settings_file"
            ok "Merged hooks and mcpServers into settings.json"
        else
            warn "Could not auto-merge settings.json"
            echo ""
            echo "  Add these to your ~/.claude/settings.json manually:"
            echo "$prepared_snippet" | jq '.'
            echo ""
        fi
    else
        # No existing settings - create from snippet
        echo "$prepared_snippet" | jq '.' > "$settings_file"
        ok "Created settings.json"
    fi
}

configure_zed() {
    # Detect Zed settings location
    local zed_settings=""
    if [[ -f "$HOME/.config/zed/settings.json" ]]; then
        zed_settings="$HOME/.config/zed/settings.json"
    elif [[ -d "$HOME/.config/zed" ]]; then
        zed_settings="$HOME/.config/zed/settings.json"
    else
        info "Zed not detected, skipping Zed configuration"
        return
    fi

    info "Configuring Zed editor..."

    # Find the claude binary: prefer wrapper if it exists, then bare binary
    local claude_bin=""
    # Check for a wrapper next to the real binary
    local real_claude
    real_claude=$(command -v claude 2>/dev/null || true)
    if [[ -n "$real_claude" ]]; then
        # Resolve through aliases/symlinks to get directory
        real_claude=$(readlink -f "$real_claude" 2>/dev/null || echo "$real_claude")
        local claude_dir
        claude_dir=$(dirname "$real_claude")
        if [[ -x "${claude_dir}/claude-wrapped" ]]; then
            claude_bin="${claude_dir}/claude-wrapped"
        else
            claude_bin="$real_claude"
        fi
    else
        warn "claude binary not found in PATH, using 'claude' as placeholder"
        claude_bin="claude"
    fi

    # Prepare Zed snippet with actual paths
    local snippet_file="$SCRIPT_DIR/templates/zed-settings-snippet.json"
    local prepared_snippet
    prepared_snippet=$(sed "s|\\\$CLAUDE_BIN|${claude_bin}|g" "$snippet_file")
    prepared_snippet=$(echo "$prepared_snippet" | sed "s|localhost:8100|${CONTEXTS_URL}|g")

    if [[ -f "$zed_settings" ]]; then
        # Check if already configured
        if jq -e '.agent_servers.claude' "$zed_settings" &>/dev/null && \
           jq -e '.context_servers."contexts-mcp"' "$zed_settings" &>/dev/null; then
            info "Zed already has agent_servers.claude and context_servers.contexts-mcp"
            return
        fi

        cp "$zed_settings" "${zed_settings}.bak.${TIMESTAMP}"
        warn "Backed up existing Zed settings.json"

        # Strip JSON comments (Zed uses JSONC) before merging
        local clean_zed
        clean_zed=$(sed 's|//.*$||' "$zed_settings" | jq '.' 2>/dev/null)

        if [[ -n "$clean_zed" && "$clean_zed" != "null" ]]; then
            local merged
            merged=$(echo "$prepared_snippet" | jq -s '.[0] * .[1]' <(echo "$clean_zed") - 2>/dev/null)

            if [[ -n "$merged" && "$merged" != "null" ]]; then
                echo "$merged" | jq '.' > "$zed_settings"
                ok "Merged agent_servers + context_servers into Zed settings"
                ok "Claude binary: $claude_bin"
            else
                warn "Could not auto-merge Zed settings"
                echo ""
                echo "  Add these to your ~/.config/zed/settings.json manually:"
                echo "$prepared_snippet" | jq '.'
                echo ""
            fi
        else
            warn "Could not parse Zed settings.json (may contain comments)"
            echo ""
            echo "  Add these to your ~/.config/zed/settings.json manually:"
            echo "$prepared_snippet" | jq '.'
            echo ""
        fi
    else
        # Create minimal Zed settings
        echo "$prepared_snippet" | jq '.' > "$zed_settings"
        ok "Created Zed settings.json"
        ok "Claude binary: $claude_bin"
    fi
}

# --- Main ---

echo ""
echo "  contexts-workflow installer"
echo "  =========================="
echo ""

# Check if stack is already running
STACK_RUNNING=false
if curl -sf --connect-timeout 2 "http://${CONTEXTS_URL}/health" &>/dev/null; then
    STACK_RUNNING=true
    ok "contexts-mcp stack detected at ${CONTEXTS_URL}"
fi

if $STACK_RUNNING; then
    # --- Hooks-only flow ---
    echo ""
    info "Stack is running. Installing hooks only."
    echo ""

    read -rp "contexts-mcp URL [${CONTEXTS_URL}]: " user_url
    CONTEXTS_URL="${user_url:-$CONTEXTS_URL}"

    # Verify health
    if ! curl -sf --connect-timeout 3 "http://${CONTEXTS_URL}/health" &>/dev/null; then
        err "Cannot reach http://${CONTEXTS_URL}/health"
        exit 1
    fi
    ok "Health check passed"
    echo ""

    check_common_prereqs
    echo ""

    install_hooks
else
    # --- Full install flow ---
    echo ""
    info "No running stack detected. Full install."
    echo ""

    # Check Docker
    check_prereq docker "Install: https://docs.docker.com/get-docker/" || exit 1
    if ! docker compose version &>/dev/null; then
        err "docker compose (v2) not found. Install Docker Compose v2."
        exit 1
    fi
    ok "docker compose v2"
    check_common_prereqs
    echo ""

    # Clone repos if not present
    if [[ ! -d "$SCRIPT_DIR/contexts-mcp" ]]; then
        info "Cloning contexts-mcp..."
        git clone https://github.com/psteinbachs/mcp-contexts.git "$SCRIPT_DIR/contexts-mcp"
        ok "contexts-mcp cloned"
    else
        info "contexts-mcp already present"
    fi

    if [[ ! -d "$SCRIPT_DIR/relay-mcp" ]]; then
        info "Cloning relay-mcp..."
        git clone https://github.com/psteinbachs/mcp-relay.git "$SCRIPT_DIR/relay-mcp"
        ok "relay-mcp cloned"
    else
        info "relay-mcp already present"
    fi
    echo ""

    # Copy config if not exists
    if [[ ! -f "$SCRIPT_DIR/config.yaml" ]]; then
        cp "$SCRIPT_DIR/config.example.yaml" "$SCRIPT_DIR/config.yaml"
        ok "Created config.yaml from example"
    fi

    # Ask for first environment name
    read -rp "First environment name [dev]: " env_name
    FIRST_ENV="${env_name:-dev}"

    # Update config with environment name if not dev
    if [[ "$FIRST_ENV" != "dev" ]]; then
        sed -i "s/^  dev:/  ${FIRST_ENV}:/" "$SCRIPT_DIR/config.yaml"
        sed -i "s/Development environment/${FIRST_ENV} environment/" "$SCRIPT_DIR/config.yaml"
    fi

    echo ""
    info "Building and starting stack..."
    cd "$SCRIPT_DIR"
    docker compose build
    docker compose up -d

    # Health check with timeout
    info "Waiting for stack to become healthy (up to 120s)..."
    SECONDS=0
    while [[ $SECONDS -lt 120 ]]; do
        if curl -sf --connect-timeout 2 "http://localhost:${CONTEXTS_PORT:-8100}/health" &>/dev/null; then
            ok "Stack is healthy!"
            CONTEXTS_URL="localhost:${CONTEXTS_PORT:-8100}"
            break
        fi
        sleep 3
    done

    if [[ $SECONDS -ge 120 ]]; then
        err "Stack failed to become healthy within 120s"
        echo "  Check: docker compose logs"
        exit 1
    fi
    echo ""

    install_hooks
fi

# --- Summary ---

echo ""
echo "  =========================="
echo "  Installation complete!"
echo "  =========================="
echo ""
echo "  Stack:     http://${CONTEXTS_URL}"
if $STACK_RUNNING; then
    echo "  Mode:      hooks-only (existing stack)"
else
    echo "  Mode:      full install (Docker stack + hooks)"
fi
echo ""
echo "  Installed files:"
echo "    ~/.claude/hooks/context-monitor.sh"
echo "    ~/.claude/hooks/context-autosave.sh"
echo "    ~/.claude/hooks/session-restore.sh"
echo "    ~/.claude/hooks/precompact-save.sh"
echo "    ~/.claude/hooks/lib/env-detect.sh"
echo "    ~/.claude/mcp-connect.sh"
echo "    ~/.claude/statusline.sh"
echo "    ~/.claude/contexts-workflow.md"
echo "    ~/.claude/settings.json (merged)"
echo "    ~/.claude/CLAUDE.md (@contexts-workflow.md added)"
if [[ -f "$HOME/.config/zed/settings.json" ]]; then
echo "    ~/.config/zed/settings.json (agent_servers + context_servers)"
fi
echo ""
echo "  Start Claude Code and type: rs ${FIRST_ENV:-dev}"
echo ""
