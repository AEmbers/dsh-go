# Changelog (`dsh-workbench-bridge`)

All notable changes to the `dsh-workbench-bridge` plugin in `AEmbers/dsh-go` are documented in this file.

## Unreleased

### Added
- **Agent Teams remote tunnel forwarding (`#8`)**:
  - Added [`createAgentTeamsProxy`](lib/agent_teams_proxy.js) and registered `workbench.bridge.agentTeams.{state,halt,plan}` on the `ds-harness-remote` E2EE RPC bridge so `@nanmicoder/dsh-agent-teams` panels work over remote relay connections via authenticated loopback requests to the host `webServer`.
- **Antigravity Desktop CDP silent remote control (`#6`)**:
  - Added [`AntigravityDesktopCdpClient`](lib/desktop_cdp.js) connecting strictly to loopback CDP (`http://127.0.0.1:19222` by default) to operate Antigravity Desktop DOM quietly in the background without foreground stealing, clipboard pollution, or full-page reloads.
  - Existing desktop IDE sessions (`~/.gemini/antigravity`) now continue in-place with native image uploads (`DOM.setFileInputFiles`), model & reasoning effort switching, live stream delta observation, and remote abort (`[data-testid="input-cancel-button"]`).
  - New Antigravity chats target Antigravity Desktop by default (`DSH_ANTIGRAVITY_NEW_SESSION_MODE=desktop`) and fall back seamlessly to the persistent `agy acp` daemon when desktop CDP is unavailable.
  - Added `antigravityDesktop: { available, cdpUrl }` status reporting in `/plugins/dsh-workbench-bridge/health` and support for `DSH_ANTIGRAVITY_CDP_URL` (enforcing loopback-only validation).

### Previous Highlights
- Persistent `agy acp` daemon client (`AntigravityAcpClient`), attachment block deduplication/restoration, tool name normalization, ETag 304 + prefix-verified delta long-polling.
- Workbench header glass integration (`GlassSurface`), per-engine/per-session CLI model preference persistence, and `Orchestrator` reasoning-effort safeguards.
