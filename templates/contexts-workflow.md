# Session Management (contexts-workflow)

## Session Restore (rs)

**`rs`** - Prompts for environment, then restores most recent session
**`rs <env>`** - Loads environment and restores most recent session
**`rs <env> "<query>"`** - Loads environment and searches for specific session

### When user types `rs` (no args):
1. List available environments from contexts-mcp config
2. Ask: "Which environment?"
3. Once specified, proceed as `rs <env>`

### When user types `rs <env>`:
1. Read `~/.claude/env/<env>.md` for bootstrap context
2. Always refresh token (tokens are in-memory on server, lost on restart):
   ```bash
   curl -s -X POST http://localhost:8100/session/<env> | jq -r '.token' | tee ~/.claude/env/<env>.session-token > /dev/null
   ```
3. Update statusline (hostname + TTY scoped):
   ```bash
   tty_id="${CLAUDE_SESSION_ID:-$(pid=$$; while [ "$pid" != "1" ]; do t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' '); [ -n "$t" ] && [ "$t" != "?" ] && echo "$t" | tr '/' '-' && break; pid=$(ps -o ppid= -p $pid 2>/dev/null | tr -d ' '); done)}"
   echo "<env>" | tee /tmp/${HOSTNAME}-claude-env-$tty_id > /dev/null
   ```
4. Get bootstrap (includes MCP servers):
   ```bash
   curl -s http://localhost:8100/bootstrap/<env>
   ```
5. Restore most recent session:
   ```bash
   curl -s -X POST http://localhost:8100/rs \
     -H "Content-Type: application/json" \
     -d '{"environment": "<env>", "limit": 1}'
   ```
6. Display summary only (run all commands silently, no curl output):
   - Environment name, token status
   - **Critical directive** (if present) - display prominently
   - MCP servers table (name, tool count, status)
   - **Priorities** (from `context.priorities` in bootstrap) - if any, show as table: urgency, category, title
   - Last session info (task, context, next steps, key artifacts if any)
   - "Ready."

### When user types `rs <env> "<query>"`:
Same as above, but search with the query instead of getting most recent.

---

## Session Save (ss)

**`ss`** - Save current session (requires active environment in conversation)

### When user types `ss`:
1. If no environment loaded in this conversation, ask which one
2. Save session:
   ```bash
   curl -s -X POST http://localhost:8100/ss \
     -H "Content-Type: application/json" \
     -d '{"environment": "<env>", "task": "<what you were doing>", "context": "<relevant details>", "next_steps": "<comma-separated list of next steps>", "key_artifacts": ["path/to/important/file.md", "path/to/design/doc.md"]}'
   ```
   Note: `next_steps` must be a string, not an array.

### key_artifacts field:
Include paths to important documents created/modified during the session that future sessions should read for context. Examples:
- Design docs: `docs/ARCHITECTURE.md`
- Implementation plans: `docs/IMPLEMENTATION.md`
- Config files with significant changes

On restore (`rs`), these artifacts are displayed so the next session knows to read them.

---

## Environment Loading (load)

**`load <env>`** - Switch to environment without restoring session

### When user types `load <env>`:
1. Read `~/.claude/env/<env>.md` - this is your active context for this session
2. Always refresh token (tokens are in-memory on server, lost on restart):
   ```bash
   curl -s -X POST http://localhost:8100/session/<env> | jq -r '.token' | tee ~/.claude/env/<env>.session-token > /dev/null
   ```
3. Update statusline (hostname + TTY scoped):
   ```bash
   tty_id="${CLAUDE_SESSION_ID:-$(pid=$$; while [ "$pid" != "1" ]; do t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' '); [ -n "$t" ] && [ "$t" != "?" ] && echo "$t" | tr '/' '-' && break; pid=$(ps -o ppid= -p $pid 2>/dev/null | tr -d ' '); done)}"
   echo "<env>" | tee /tmp/${HOSTNAME}-claude-env-$tty_id > /dev/null
   ```
4. Get bootstrap (includes MCP servers):
   ```bash
   curl -s http://localhost:8100/bootstrap/<env>
   ```
5. **Auth profile check**: If bootstrap returns an `auth` block with `type: oauth`:
   - Read the profile from `~/.claude/credentials/<auth.profile>.json`
   - Compare with current active credentials:
     - **Linux**: compare `claudeAiOauth.accessToken` with `~/.claude/.credentials.json`
     - **macOS**: compare with `security find-generic-password -s "Claude Code-credentials" -w`
   - If tokens differ: activate the new profile (copy/Keychain update), then display:
     **"Credentials updated to '<profile>'. Restart Claude to activate."**
   - If same: no action needed
   - If profile file missing: warn and continue without switching
6. Display summary only (run all commands silently, no curl output):
   - Environment name, token status
   - **Auth profile** (if present) — show profile name and whether it matches current session
   - **Critical directive** (if present) - display prominently
   - MCP servers table (name, tool count, status)
   - **Priorities** (from `context.priorities` in bootstrap) - if any, show as table: urgency, category, title
   - "Ready."

---

## Critical Directives

Each environment can define a `critical_directive` - a rule that must always be followed. These are returned in the bootstrap response and displayed prominently on `rs` or `load`.

When a critical directive is active:
- Display it prominently at session start
- Consider it before any significant operation
- It overrides convenience in favor of safety

Directives are configured per-environment in `contexts-mcp/config.yaml`.

---

## Additional Context Sources

For detailed knowledge beyond session restore:
- `GET http://localhost:8100/bootstrap/<env>` - config + qdrant knowledge
- `GET http://localhost:8100/context?environment=<env>&query=<search>` - search stored facts

---

## Shortcuts

| Shortcut | Action |
|----------|--------|
| ss | Save session to qdrant |
| rs | Restore session from qdrant |
| st | Show MCP tools (servers + tool counts) |
| pb | Search pensieve: `pensieve search "<query>" --env <env>` |

### When user types `st`:
Get current environment from statusline, load its token, query the correct relay:
```bash
# Get current environment from statusline
tty_id="${CLAUDE_SESSION_ID:-$(pid=$$; while [ "$pid" != "1" ]; do t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' '); [ -n "$t" ] && [ "$t" != "?" ] && echo "$t" | tr '/' '-' && break; pid=$(ps -o ppid= -p $pid 2>/dev/null | tr -d ' '); done)}"
env=$(cat /tmp/${HOSTNAME}-claude-env-$tty_id 2>/dev/null)

# Get token for this environment
token=$(cat ~/.claude/env/${env}.session-token 2>/dev/null)

# Get relay URL and query servers
relay_url=$(curl -s "http://localhost:8100/env?token=$token" | jq -r '.url')
curl -s "$relay_url/api/servers" | jq -r '.[] | select(.enabled) | "\(.name): \(.tools_count) tools (\(.status))"'
```

Note: Requires environment to be loaded first (`rs <env>` or `load <env>`).
