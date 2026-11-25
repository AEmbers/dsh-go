# dsh-workbench-bridge

Multi-CLI bridge plugin for DeepSeek Harness & DSH Go.

## Features
- Aggregates sessions from **Antigravity** (`~/.gemini/antigravity` desktop + `~/.gemini/antigravity-cli`), **Claude Code** (`~/.claude`), and **Codex** (`~/.codex`).
- Exposes standardized read/prompt/abort/model/upload/file HTTP & E2EE RPC endpoints under `/plugins/dsh-workbench-bridge/*`, secured via the DSH host `connection` guard.
- **Antigravity Desktop (CDP) Silent Remote Control**:
  - Connects strictly over loopback (`127.0.0.1` / `localhost` / `::1`) via standard Electron CDP (`--remote-debugging-port=19222`), without bringing the desktop window to front, touching the Windows clipboard, or accessing private tokens/RPCs.
  - Continues existing Antigravity Desktop sessions in-place, opens new Antigravity chats on desktop by default, attaches images silently via `DOM.setFileInputFiles`, switches models & reasoning effort, streams live DOM output updates, and supports remote abort.
- **Persistent `agy acp` Fallback & CLI Mode**:
  - Keeps a persistent `agy acp` JSON-RPC daemon for Antigravity CLI sessions and seamlessly falls back to ACP when the desktop window is offline.

## Configuration (Environment Variables)
- `DSH_ANTIGRAVITY_CDP_URL`: Loopback CDP endpoint for Antigravity Desktop (default: `http://127.0.0.1:19222`; non-loopback URLs are rejected).
- `DSH_ANTIGRAVITY_NEW_SESSION_MODE`: Default target for new Antigravity sessions (`desktop` or `acp`; default: `desktop`, automatically falls back to `acp` when desktop CDP is unavailable).

## Endpoints
- `GET /plugins/dsh-workbench-bridge/health` (includes `engines` and `antigravityDesktop: { available, cdpUrl }`)
- `GET /plugins/dsh-workbench-bridge/sessions` (with strong `ETag` / `304`)
- `GET /plugins/dsh-workbench-bridge/models/:engine`
- `GET /plugins/dsh-workbench-bridge/sessions/:engine/:id/messages` (supports `ETag`, `afterCount`+`baseHash` delta, and `waitMs` long-polling)
- `POST /plugins/dsh-workbench-bridge/uploads`
- `POST /plugins/dsh-workbench-bridge/sessions/prompt`
- `POST /plugins/dsh-workbench-bridge/sessions/abort`
- `POST /plugins/dsh-workbench-bridge/files/{stat,read-bytes,read-text,list}`
