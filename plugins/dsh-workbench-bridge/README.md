# dsh-workbench-bridge

Multi-CLI bridge plugin for DeepSeek Harness & DSH Go.

## Features
- Aggregates sessions from **Antigravity** (`~/.gemini/antigravity`), **Claude Code** (`~/.claude`), and **Codex** (`~/.codex`).
- Exposes standardized read/prompt/abort HTTP endpoints under `/plugins/dsh-workbench-bridge/*`, secured via the DSH host `connection` guard.
- Executes non-interactive turns (`agy --print`, `claude -p`, `codex exec`) and streams live running status back to DSH Go.

## Endpoints
- `GET /plugins/dsh-workbench-bridge/health`
- `GET /plugins/dsh-workbench-bridge/sessions` (with strong `ETag` / `304`)
- `GET /plugins/dsh-workbench-bridge/sessions/:engine/:id/messages`
- `POST /plugins/dsh-workbench-bridge/sessions/prompt`
- `POST /plugins/dsh-workbench-bridge/sessions/abort`
