# contexts-workflow

Session memory and environment management for Claude Code.

Claude Code has no memory between sessions. This project gives it one: automatic session save/restore, multi-environment switching, and context lifecycle hooks that prevent lost work when the context window fills up.

## Architecture

```
+----------------------------------------------------------+
|                                                          |
|  Claude Code                                             |
|                                                          |
|    CLAUDE.md (@contexts-workflow.md)                     |
|    rs / ss / load / st commands                          |
|                                                          |
|    Hooks:                                                |
|      SessionStart  ->  auto-restore                      |
|      PreCompact    ->  auto-save before compaction       |
|      PostToolUse   ->  auto-save at 85% context          |
|      Stop          ->  context usage warnings            |
|                                                          |
|    MCP (via mcp-remote):                                 |
|      contexts-mcp -> relay-mcp -> tool servers           |
|                                                          |
+-----------------------------+----------------------------+
                              |
                              v
+----------------------------------------------------------+
|                                                          |
|  Docker Stack                                            |
|                                                          |
|  +--------------+  +--------------+  +----------------+  |
|  | contexts-mcp |  |   relay-mcp  |  |     qdrant     |  |
|  | :8100        |  |  (internal)  |  |   (internal)   |  |
|  | session mgmt |  |  MCP proxy   |  | vector storage |  |
|  +--------------+  +--------------+  +----------------+  |
|                                                          |
+----------------------------------------------------------+
```

## Prerequisites

- **Docker** with Compose v2 (full install only)
- **Node.js** with `npx` (for `mcp-remote`)
- **jq** and **curl**
- **Claude Code** CLI

## Quick Start

```bash
git clone https://github.com/psteinbachs/contexts-workflow.git
cd contexts-workflow
./setup.sh
```

The installer auto-detects whether you need the full Docker stack or just the hooks (if you already have contexts-mcp running elsewhere). It handles everything:

- Installs hooks and configures `~/.claude/settings.json` (including `autoCompact: false`)
- Adds `@contexts-workflow.md` to `~/.claude/CLAUDE.md`
- Configures Zed editor if detected (`agent_servers` + `context_servers`)
- Auto-detects your `claude` binary (or wrapper) for the Zed agent config

Then start Claude Code:

```
> rs dev          # Restore last session for "dev" environment
> ss              # Save current session
> load prod       # Switch to "prod" without restoring
```

## How Session Memory Works

1. **Save** (`ss`): Claude summarizes the current session (task, context, next steps) and stores it in Qdrant as a vector embedding
2. **Restore** (`rs <env>`): Fetches the most recent session for the environment from Qdrant. Claude picks up where it left off.
3. **Search** (`rs <env> "query"`): Semantic search across all saved sessions
4. **Auto-save**: Hooks automatically save before context compaction and at 85% context usage
5. **Auto-restore**: After `/clear` or compaction, the SessionStart hook restores the last session automatically

## How Environments Work

Environments are isolated workspaces. Each has:
- **Session history** stored separately in Qdrant
- **MCP server routing** through relay-mcp (different tools per environment)
- **Environment file** (`~/.claude/env/<name>.md`) describing boundaries and access
- **Optional critical directive** - a safety rule displayed at session start
- **Statusline colors** for visual identification

### Environment Detection

Hooks detect the current environment using this priority:
1. TTY-scoped statusline file (`/tmp/${HOSTNAME}-claude-env-${tty_id}`)
2. CWD map file (`~/.claude/env/cwd-map.conf`)
3. `CONTEXTS_DEFAULT_ENV` environment variable
4. Fallback: `dev`

### CWD Map

Map directories to environments in `~/.claude/env/cwd-map.conf`:

```conf
/home/user/projects/webapp=dev
/home/user/infra=prod
/home/user/ml-pipeline=research
```

## Registering MCP Servers

MCP servers are managed through relay-mcp, not in Claude Code's settings directly. Register servers via the relay API or its config file. See [relay-mcp documentation](https://github.com/psteinbachs/mcp-relay) for details.

## Hooks Reference

| Hook | Event | What It Does |
|------|-------|-------------|
| `session-restore.sh` | SessionStart (clear/compact) | Restores last session from Qdrant |
| `precompact-save.sh` | PreCompact | Saves session before Claude compacts context |
| `context-autosave.sh` | PostToolUse | One-time auto-save when context hits 85% |
| `context-monitor.sh` | Stop | Warns about context usage, auto-saves at critical levels |
| `statusline.sh` | StatusLine | Displays environment, model, context %, project |
| `mcp-connect.sh` | MCP startup | Dynamic token-aware connection to contexts-mcp |

All hooks use `CONTEXTS_URL` environment variable (default: `localhost:8100`).

## Configuration Reference

### `config.yaml`

```yaml
qdrant:
  url: http://qdrant:6333
  collection: sessions

environments:
  dev:
    description: "Development"
    relay_url: http://relay-mcp:8000
    # critical_directive: "Safety rule shown at session start"
    # statusline:
    #   bg_rgb: "76;86;106"
    #   icon: ""
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTEXTS_URL` | `localhost:8100` | contexts-mcp API URL |
| `CONTEXTS_PORT` | `8100` | Docker-exposed port |
| `CONTEXTS_DEFAULT_ENV` | `dev` | Fallback environment name |

### Zed Editor

The installer configures Zed automatically if `~/.config/zed/settings.json` exists. It adds:

- **`agent_servers.claude`**: Points Zed's agent at your `claude` binary (or wrapper like `claude-wrapped` if found alongside it). Sets `CLAUDE_SESSION_ID=zed` so hooks know the context.
- **`context_servers.contexts-mcp`**: Gives Zed direct MCP access to contexts-mcp via `mcp-remote`.

To use a custom wrapper, place it next to the `claude` binary with the name `claude-wrapped` and the installer will prefer it.

## Troubleshooting

**Stack won't start**: Check `docker compose logs`. Common issue: port 8100 already in use. Set `CONTEXTS_PORT=8200` in `.env`.

**Hooks not firing**: Verify `~/.claude/settings.json` has the hooks configuration. Run `cat ~/.claude/settings.json | jq '.hooks'`.

**MCP connection fails**: Ensure `npx` is available and `mcp-remote` can be installed. Test: `npx -y mcp-remote --help`.

**Wrong environment detected**: Check `cat /tmp/${HOSTNAME}-claude-env-*` or add entries to `~/.claude/env/cwd-map.conf`.

**Session not restoring**: Verify Qdrant has data: `curl http://localhost:8100/health`. First session will be empty - save one first with `ss`.

## Uninstall

```bash
# Remove hooks
rm ~/.claude/hooks/{context-monitor,context-autosave,session-restore,precompact-save}.sh
rm -rf ~/.claude/hooks/lib/
rm ~/.claude/{mcp-connect,statusline,contexts-workflow}.sh

# Remove Docker stack (if full install)
cd /path/to/contexts-workflow
docker compose down -v  # -v removes data volumes

# Restore settings.json from backup
cp ~/.claude/settings.json.bak.* ~/.claude/settings.json
```

## License

MIT
