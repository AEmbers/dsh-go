# dsh-go 三向适配报告（上游 v1.0.14 同步）

- 仓库：`D:\dsh\forks\dsh-go`
- 分支：`adapt/upstream-1c5b2200`（从 `a103a4a6` 建，`git rebase --onto 1c5b2200 e1d5a115`）
- 结果 HEAD：`f03743c0` `fix(app): 四大插件适配收口（host 归属 / tabId / 语音焦点）`，父提交 `1c5b2200`
- 旧基线：`e1d5a115`（上游 PR #726）→ 新基线：`1c5b2200`（v1.0.14）
- `git rev-list --left-right --count upstream/main...HEAD` = **0 / 1**（上游已无领先提交，我方仅 1 个自有提交仍在其上）
- 工具链：Flutter 3.47.7 / Dart 3.13.5 / engine `abaf9c5237`，包装脚本 `/d/dsh/tools/fl3477.sh`

---

## 0. 三条对任务简报的纠正（先读这段）

简报里的三处描述与仓库实测不符，本报告全部以实测为准：

| # | 简报说法 | 实测 | 依据 |
|---|---|---|---|
| 1 | 上游 v1.0.14 让 `sdk/plugin-kit/lib/check.js` 净减 88 行、`testing.js` 也动了 | **上游对 `sdk/` 零文件变更**。那两个文件的 blob 两端完全相同：`check.js` = `d516e02a…`（e1d5a115 与 1c5b2200 同一 hash）、`testing.js` = `25e0fbfc…`。所谓 86 行改动（`check.js` +83/−3、`testing.js` +5/−1）来自**我们自己的提交 `a103a4a6`** | `git diff --stat e1d5a115..1c5b2200 -- sdk/` 输出为空；`git rev-parse e1d5a115:sdk/plugin-kit/lib/check.js` 与 `1c5b2200:` 同 hash |
| 2 | 新增 `app/assets/skills/dsh-go-plugin/{kit-lib-check.js,kit-lib-testing.js}` | 这两个文件在 `e1d5a115` **就已存在**（`git cat-file -e` 两端皆 yes），且与 `sdk/plugin-kit/lib/*` **逐字节相同**（`git hash-object`：`check` 两侧同为 `d89fbfc6…`，`testing` 两侧同为 `a0e134c1…`）→ 是随 App 分发的副本，不是新契约面 | `git cat-file -e` 双向 + `git hash-object` |
| 3 | tavern 的 `POST /tavern/api/*` 必须自兜一次鉴权；SSE 每次推前不用重查 | tavern **已经**有 fail-closed 守卫（`lib/http/guard.js` 的 `makeGuard(ctx)`，`ctx.get('connection')` 为 undefined → 503 `{code:'unavailable'}`），覆盖全部已注册路由含 POST；并且 tavern 代码里**没有任何 SSE**（无 `text/event-stream`、无 `res.write(`） | `lib/http/guard.js`、`lib/http/routes.js:118-121`、全仓 grep |

**对结论的影响**：交付 2 的「plugin-kit 契约变更影响」答案是**零变更、无需适配**；交付 3 的「view/slot 渲染核对」实际是**无渲染面可核**（我们没有任何插件声明 dshGo 清单）；交付 3 的「tavern POST 自兜 / SSE 清理」两条重点在现存代码上**已不成立或不存在**。

---

## 1. 309 提交分类概览

`e1d5a115..1c5b2200` = **309 提交 / 699 文件 / +91796 / −2900**。

### 1.1 目录分布（commits / files）

| 目录 | commits | files |
|---|---|---|
| `app/android` | 209 | 314 |
| `app/lib` | 77 | 113 |
| `app/test` | 84 | 97 |
| `runtime/tests` | 18 | 30 |
| `runtime/bridge` | 9 | 18 |
| `runtime/patches` | 12 | 11 |
| `app/assets` | 20 | 15 |
| `packages/dsh_client` | 3 | 20 |
| `services/share-worker` | 3 | 24 |
| `tooling/companion` | 3 | 12 |
| `docs/guide` | 12 | 7 |
| **`sdk`** | 1 | **0** |

### 1.2 提交类型前缀

`phone` 121 · `feat` 76 · `fix` 70 · `test` 13 · `chore` 7 · `docs` 5 · `style` 1 · Merge 16。

### 1.3 scope 分布（前 12）

`phone` 99 · `runtime` 12 · `companion` 12 · `diagnostics` 8 · `remote` 4 · `bridge` 4 · `pets` 3 · `guide` 3 · `notify`/`native`/`media`/`files`/`l10n` 各 2。

**主线是 phone（99 次）+ companion（12 次）+ runtime 补丁（12 次）**。phone 批次是「Pro 34xx」系列（回放 Trace / Main 事件末门 / 导航材料 / 执行子集 / 技能测试 / 截图 / 计数债务），companion 批次带来 Live2D 适配契约，runtime 批次带来运行时补丁。

### 1.4 上游新增的关键面（对本次适配有意义的）

- `app/assets/skills/companion-adapt/{SKILL.md,contract.txt,manifest.json}` —— **真新增**（e1d5a115=no / 1c5b2200=yes）。Live2D 伴生 App 适配契约，详见 §4。
- `runtime/bridge/dsh-go-bridge/lib/companion/{signals.js,signals-schema.js}` —— **真新增**（signals.js e1d5a115=no / 1c5b2200=yes）。
- `runtime/patches` +11 文件 / +1722 行。全目录现 **117 个 `.diff` + `pins.json`**，命名靠 `z` 前缀累积排序（`…z-companion-signals.diff`、`…z-companion-recall-gates.diff`、`…z-phone-caller.diff`、`…z-phone-run-end{,-schema,-retry,-live-retry}.diff`、`…z-agent-team-input-recovery.diff`、`…z-terminal-readiness-clock.diff` 等）。**上游自己也在打运行时补丁**，补丁层是本仓库的正常机制，不构成冲突源。

---

## 2. 冲突清单与解法

**冲突总数 = 1**。`app_en.arb` / `app_zh.arb`（上游各改 26 次）、`gen/app_localizations{,_en,_zh}.dart`（各 24 次）、`app/test/chat/support/harness.dart`（4 次）、`app/lib/ui/chat/chat_screen.dart`（2 次）、`docs/guide/README.md`（2 次）、`app/lib/l10n/parts/bots_{en,zh}.arb`（各 2 次）**全部 auto-merge 成功，零人工干预**。

### 2.1 `app/tool/l10n_merge.py`

| 项 | 内容 |
|---|---|
| 上游改了啥 | 给写 ARB 的 `open()` 加 `newline='\n'`，写成单行，并带注释 `# LF on every platform: Windows would write CRLF, and CI diffs against LF.` |
| 我们改了啥 | 同一个改动（加 `newline='\n'`），但把参数按行折开成多行写法 |
| 为什么这么合 | 取**上游版本**。两方语义完全等价（都是强制 LF 输出），上游版多了注释、且是 CI 依赖的形态；保留我方折行只会让下次生成器改动再冲突一次。收口后 `git diff 1c5b2200 -- app/tool/l10n_merge.py` 输出为空，最终形态 `:291 with open(os.path.join(L10N, f'app_{lang}.arb'), 'w', encoding='utf-8', newline='\n') as f:` |

### 2.2 四大适配完好性核验（未丢、无需等价替代）

rebase 后逐条 grep 证实四大适配全部在：

| 适配 | 证据 |
|---|---|
| host 归属判据 `_live(client, generation)` | `app/lib/state/agent_teams_state.dart:62` 与 `app/lib/state/voice_mode_state.dart:175` 各有 `bool _live(DshClient client, int generation) =>`；`agent_teams_state.dart:57` 的 `_generation`、`:63` 的判据 `!_disposed && generation == _generation && identical(client, _owner)` 完整 |
| tabId 重连稳定 | `app/lib/state/voice_mode_state.dart` 内 tabId 重连路径与 focus-after-drop 用例在位，测试见下 |
| 语音焦点归属 | `app/test/chat/voice_focus_test.dart` 通过 |
| AgentTeams 控制器 generation | `app/test/agents/agent_teams_state_test.dart`、`app/test/agents/team_inline_card_test.dart`、`app/test/chat/rows_agent_teams_card_test.dart`、`app/test/bots/room_goal_board_test.dart`、`app/test/bots/bots_goal_board_test.dart`、`app/test/voice/voice_mode_state_test.dart` 全绿 |

我方 96 个文件全部落入 rebase 结果；上游 0 次改动的那些文件（`agent_teams_state.dart`、`voice_mode_state.dart`、`agent_teams_{en,zh}.arb`、`voice_mode_{en,zh}.arb`、`team_activity_page.dart`、`team_inline_card.dart`、`room_goal_board.dart`）原样保留。

---

## 3. 三向核对表

### 3.1 我们 → dsh-go（我们的插件能不能装进 dsh-go）

检查器：`node sdk/plugin-kit/bin/check.mjs <dir> [--load]`（Node v24.19.0）。

| 插件 | 目录 | 静态检查 | `--load` | 结论 | 要改的 |
|---|---|---|---|---|---|
| **dsh-tavern** | `C:/Sophia/dev-plugin/dsh-tavern` | exit 0，仅 `/engines/dsh` 之外无 error；`noDshGo` 为 warn（「没有 dshGo 清单：只有工具卡（presentationMeta）这类零成本扩展」） | exit 0，注册 8 工具：`tavern_character_import`、`tavern_lore_search`、`tavern_lore_read`、`tavern_state_get`、`tavern_state_update`、`tavern_memory_recall`、`tavern_dice`、`tavern_rp_turn` | **能加载** | 无（若要原生 UI，才需补 dshGo 清单，见 §3.2） |
| **dsh-live2d-studio** | `D:/dsh/dsh-live2d-studio` | exit 0，同 warn | exit 0，注册 5 工具：`live2d_split_psd`、`live2d_rig_preview`、`live2d_export`、`live2d_mascot`、`live2d_job_status` | **能加载** | 无 |
| **sophia-core** | `C:/Sophia/dev-plugin/sophia-core-v2` | exit 0 | exit 0，大量 ready 行（memory / effort / guard / handoff / core-control 路由） | **能加载** | 无 |
| **ds-bot** | `C:/Users/Administrator/.dsh/profiles/desktop/node_modules/ds-bot`（v0.3.2） | `/engines/dsh` 提示「没写 engines.dsh」 | **exit 2 两连败**：无 `DSH_DIR` → `Cannot find package '@deepseek-ai/dsh-scope' imported from ...\ds-bot\src\host\turns.js`；设 `DSH_DIR="C:/Users/Administrator/AppData/Local/Programs/DeepSeek Harness/resources/app/dsh"` 后 → `ctx.tools.guard is not a function` | **宿主半侧加载失败** | ① 补 `engines.dsh` 显式范围；② `@deepseek-ai/dsh-scope` 需解析到宿主 node_modules（或改成 `ctx.inject(['*'], …)` 取 scope）；③ `ctx.tools.guard` 不是本宿主暴露的 API，需改用现存面 |
| **dsh-xdpool** | **全机不存在** | — | — | **不存在，无法核对** | 需先确认它是否还应存在；`find /c/Sophia /d/dsh -iname "*xdpool*"` 无结果，profile `package.json` 里也无 |

**engines.dsh 实测值**（简报说「`"*"` 是恒真校验应改显式范围」——在现存 package.json 上**都已落实**）：

| 插件 | `engines.dsh` |
|---|---|
| dsh-tavern | `>=0.2.2-rc.1 <0.3.0` |
| dsh-live2d-studio | `>=0.2.2-rc.1 <0.3.0-0` |
| sophia-core | `>=0.2.1-alpha.5 <0.3.0-0` |
| ds-bot | **undefined** ← 唯一缺口 |

且 `sdk/plugin-kit/lib/check.js:178` 只判断 `typeof pkgJson.engines?.dsh !== 'string'`（**只查类型，不查范围真假**），所以 `"*"` 那条契约文档意见即便在历史版本上存在，检查器也不会拦——结论仍是「修 ds-bot 的 undefined」这一项。

**plugin-kit 契约变更影响**：`sdk/plugin-kit` 上游零变更（§0 第 1 条），**对五个插件的影响为无**。`app/assets/skills/dsh-go-plugin/kit-lib-{check,testing}.js` 是同一份代码的 App 内副本。

### 3.2 dsh-go → 我们（dsh-go 能不能认并渲染我们的插件）

| 核对面 | 结论 | 证据 | 要改的 |
|---|---|---|---|
| **dshGo 清单 / contributes / views / slots** | **我们没有一个插件声明 dshGo 清单** → contributes 面全空，dsh-go 的原生 UI 渲染面**当前完全没被我们触及**。这是「无从渲染」，不是「渲染错」 | 4 个实际存在的插件 `check.mjs` 全报 `noDshGo` warn | 无（如要原生卡片，按 `app/assets/skills/dsh-go-plugin/SKILL.md` 补 `pkg.dshGo` + `lib/index.js`；工具卡走 `output.presentationMeta` 返回 `{"dsh-go/view": …}`，**不需要清单**） |
| **plugin_inventory 列表可见性** | 我们的插件会作为**普通插件**出现在 inventory 里，可读状态 | `packages/dsh_client/lib/src/engine_settings_api.dart:671-675` `Future<PluginInventory> pluginInventory()`（先 `tryBackgroundListRead(BackgroundListKind.inventory)`，再 `rpc.call('pluginInventory/list')`）；消费方 `app/lib/state/engine_settings_state.dart:1198 pluginInventoryProvider`、`app/lib/ui/plugins/plugin_inventory_page.dart:129`、`app/lib/ui/plugins/plugin_load_status.dart:25`、`app/lib/ui/engine_settings/engine_settings_hub.dart:103-105`（`SettingsPageId.pluginInventory`） | 无 |
| **岛屿安全门 / routeGuard** | 由 host 的 bridge 提供，与插件是否声明 dshGo 无关 | `app/lib/plugins/seams/seat_state.dart:79-84 seatRouteGuardReportProvider` → `bridgeInventoryProvider.select((s) => s.value?.routeGuard)`；探针 `app/lib/ui/plugins/islands/island_gate.dart:52 const routeGuardProbePath = '/dsh-go/v1/inventory'` | 无 |
| **bridge 契约** | 完整，四条：`GET /dsh-go/v1/inventory`（v/bridge/release/bootRev/currentRev/packages/slots/occupancy/routeGuard/routeGuardMode）、`POST /dsh-go/v1/occupancy`、`installFallbackGuard(webCtx, open)`、`rejectionOf(webCtx, req)` | `runtime/bridge/dsh-go-bridge/lib/index.js:319`（`routeGuardMode = options.guardRoutes === false ? "off" : installFallbackGuard(...)`）、`:162`（`return connection === undefined ? 503 : connection.requestRejection(req)`）；canary `/dsh-go-guard-canary` + `guardProbe` | 无 |
| **tavern `POST /tavern/api/*` 自兜鉴权** | **已存在，不是缺口**。`lib/http/guard.js makeGuard(ctx)` 三段式 fail-closed：`ctx.get('connection')` undefined → 503 `{code:'unavailable', message:'connection service is not available; write routes are closed'}`；有 rejection → 用其状态码；否则放行。导出 `makeGuard as makeReadGuard`。`lib/http/routes.js:118-121` 另有前置断言 `if (webServer === undefined \|\| typeof webServer.register !== 'function') throw new TypeError('registerRoutes: opt.webServer is required (has .register)')` | 同上 | 无 |
| **tavern SSE 清理** | **tavern 侧不存在 SSE**：全仓无 `text/event-stream`、无 `res.write(`（`lib/store/lore.js:153` 仅一句注释提到 SSE）。该条对 tavern 不适用 | grep 全仓 | 无（若将来加 SSE，才需按 bridge 的 guard 语义做每连接一次校验） |
| **tavern 路由表** | `BASE = /plugins/dsh-tavern`，`API_METHODS` 15 条（GET：`/health` `/characters` `/chats` `/branch` `/lore/books` `/lore/search` `/swipe/list` `/character/portrait`；POST：`/turn` `/import/character` `/import/lore` `/swipe/select` `/branch/fork` `/chat/create`），`isApiPath()` 与 `methodHandler()` 都读这张表 | `lib/http/routes.js` | 无 |

**结论（第三向）**：dsh-go 认我们插件的方式只有 inventory 列表 + 工具卡，两者都工作；view/slot 原生渲染面我们没有任何声明，因此**没有需要修的东西，只有「要不要接入」的决策**。tavern 简报里点名的两条重点，一条已实现、一条不存在。

---

## 4. 二线 live2d × 上游 `companion-adapt` 契约对接结论

### 4.1 契约要什么

`app/assets/skills/companion-adapt/` 三件（`SKILL.md` / `contract.txt` / `manifest.json`，manifest 把 `contract.txt` 映射到 `references/contract.txt`，由 `tooling/companion/sync-adapt-skill.mjs` 与 App 代码同步）：

- **输入** `dsh-go/companion-adapt-request` v1，`target = app-local-adapter-v1`，含 `vocabulary` + `probe` + `verifiedEffects` + `wanted` + `truncation`（+ 可选 `current` / `currentDropped` / `userFeedback`）。
- **输出** 五块：`params` / `emotions` / `actions` / `zones` / `notes`（可选 `tail`）。
  - `params`：键必须取自 **18 个标准参数**（`companionAdaptParams`，`companion_adapt_contract.dart:9-28`）：`ParamAngleX/Y/Z`、`ParamBodyAngleX/Y/Z`、`ParamBreath`、`ParamEyeLOpen/ROpen`、`ParamEyeBallX/Y`、`ParamEyeSmile`、`ParamMouthOpenY`、`ParamMouthForm`、`ParamBrowLY/RY`、`ParamBrowLAngle/RAngle`；值为 `{ids, scale, offset}`，`|scale|<=1000 且 !=0`、`|offset|<=1000`。
  - `emotions`：**10 键**（`calm|happy|shy|sad|angry|surprised|confused|smug|sleepy|worried`），每个 `{expression, face}`；`face` 键必须落在 `_faceRanges`（16 项，**排除** `ParamEyeLOpen/ROpen`）且必须有通道；`expression` 必须命中 `verifiedEffects.expressions`。
  - `actions`：**12 键**（`nod|nodSmall|shake|tilt|tiltLeft|lookUp|recoil|duck|sway|stretch|yawn|wave`），每个 `{motion}`，`motion` 必须命中 `verifiedEffects.motions`。
  - `zones`：`{id: head|face|body|tail|legs, from, to, xFrom?, xTo?}`，`from=(1-top)/2`、`to=(1-bottom)/2`、`0<=from<to<=1`、`xFrom<xTo` 且必须**成对**。zones **只能原样复制 `probe.knownZones`**（`_sameZone` 比对），不能自创。
  - `notes`：≤60 Unicode 字符。
  - **硬禁**：`moc`（App 自算）、`toggles`、`pose`、代码、URL、`framing`（本期无相机证据，App 明确拒收）。
- **白名单机制**：`_effects(evidence, loaded)`（`:361-365`）只接受「名字出现在 probe 的 `loadedExpressions`/`loadedMotions` 里 **且** `evidence[name]` 非空 **且** 名字 ≤160 字 **且** 不匹配 `_protected` 正则（watermark/copyright/signature/outfit/clothes/costume/opacity/hide/invisible/水印/署名/版权/版權/换装/換裝/服装/衣装/着替/透明/非表示）」的条目。`loaded*` 名单本身不算证据。
- **probe 不是离线可算的**：由 `app/assets/companion/stage.js:785-833 probeReport()` 在 Cubism core 里跑模型现场产出（`raw = model.core.getModel()`，参数上限 800 / parts 上限 300），`zonesFrom` 由 loadAdapter 分支决定（`:767 'adapter'` / `:770 'character'` / `:773 'hitAreas'` / `:777 'default'`），`emotionsFrom = character.emotions ? 'character' : 'default'`。
- App 侧实现全在 `app/lib/companion/companion_adapt_contract.dart`（`companionAdaptInput()` :408-466、`companionAdaptRequest()`、`companionAdaptFullRequest()` 产出 `/companion-adapt\n\n<json>`、`companionAdaptJson()` 取首个 `{` 到末个 `}`、`companionAdapterCheck()` :500-636、`companionAdapterEmpty()`），调用点 `app/lib/companion/companion_adapt.dart:55,57`。

### 4.2 live2d 现在有什么

产物在 `/d/dsh/dsh-live2d-studio/build/anim-pack/char_0{1,2}/` 与 `build/core/char_0{1,2}/`，三件 `model.json` / `motions.json` / `meta.json`。

| 契约字段 | live2d 能供吗 | 实测 |
|---|---|---|
| `params` | **部分**。`meta.json.paramRanges` 有 19 个参数，与 18 词表 **交集 14 / 缺 4 / 多 5** | 命中：`ParamAngleX/Y/Z`、`ParamBodyAngleX`、`ParamBodyAngleZ`、`ParamBreath`、`ParamEyeLOpen/ROpen`、`ParamEyeBallX/Y`、`ParamMouthOpenY`、`ParamMouthForm`、`ParamBrowLY/RY`。**缺**：`ParamBodyAngleY`、`ParamEyeSmile`、`ParamBrowLAngle`、`ParamBrowRAngle`。多（live2d 自有）：`ParamHairFront`、`ParamHairSide`、`ParamHairBack`、`ParamArmL`、`ParamArmR` |
| `emotions` | **不能** | `verifiedEffects.expressions` 恒空——产物**没有 expressions 概念**。且即使补，`happy`/`shy` 依赖 `ParamEyeSmile`、`angry`/`worried` 依赖 `ParamBrowLAngle/RAngle`，这 4 个参数在 char_01/02 上都**不存在**，`companionAdapterCheck` 会把这些 face 键丢进 `dropped` |
| `actions` | **不能** | `verifiedEffects.motions` 恒空——`motions.json` 只有 `idleMotion` 四条程序化轨道（`breath` 3.2s sine、`blink` pulse 3.4–6.8s closedSec 0.12、`sway` 6.4s、`hairIdle` 2.6s）+ `voiceLipSync`（`ParamMouthOpenY`，oneEuro minCutoff 1.2 / beta 0.02 / attack 45ms / release 110ms），**没有命名 motion 列表**。`duck`/`stretch` 写 `ParamBodyAngleY`，该参数同样不存在 |
| `zones` | **能**（4 区，已实算合法） | 由 `model.json` 层 bbox 换算（`from = yTop/(2H)`、`to = yBot/(2H)`、`x = xPx/W`，`W=1024 H=1536`）：`head {0.0075, 0.1488, 0.4023, 0.5996}`、`face {0.0143, 0.0824, 0.4121, 0.5869}`、`body {0.0804, 0.2819, 0.2744, 0.7275}`、`legs {0.1729, 0.499, 0.3379, 0.6631}`。**`tail` 无对应层，不能填** |
| `notes` | 能 | 可写「表情与动作缺资源证据」 |

分组依据：head = `cat_ear/front_hair/face_base/brow/eye_L/eye_R/mouth/blush/neck`；face = `face_base/brow/eye_*/mouth/blush`；body = `clothing_body/clothing_sleeve_L/R/arm_L/R/body_base`；legs = `bottomwear/legwear/footwear`。空层 `mouth/blush/cat_ear` bbox 全 0，已跳过。

### 4.3 结论：现在挂不进去，差在三处硬证据

1. **产物无 `model3.json` / `.moc3`**。live2d 全仓 `find -name "*.moc3" -o -name "*.model3.json" -o -name "*.exp3.json" -o -name "*.motion3.json"` **全空**（`docs/SPEC.md` 只提到格式名）。而 App 的 `CompanionPackStore` **硬要求** `*.model3.json` 存在（`app/lib/companion/companion_pack.dart:190、:249`），`_dataExtensions`（`:109`）= `{'.json','.moc3','.png','.jpg','.jpeg','.webp','.wav','.mp3','.txt','.md'}`（`.psd` 不在内，`:182` 注释说 `.psd`/`.cmo3` 被「留下而不报错」）；runtime 还要 `character/index.json` + `runtime/live2dcubismcore.min.js`（`:133-134`）。→ **一个 live2d 动画包连 App 的 pack 安装都过不了，遑论进 adapt 流程**。
2. **无命名 expressions / motions 资源** → `verifiedEffects` 恒空 → `emotions`(10) 与 `actions`(12) 两个字段**在本机产物上根本无法填**，只能留空。
3. **参数词表交集只有 14/18**，缺的 4 个恰好是 `happy`/`shy`/`angry`/`worried` 表情与 `duck`/`stretch` 动作依赖的通道（`ParamEyeSmile`、`ParamBrowLAngle`、`ParamBrowRAngle`、`ParamBodyAngleY`）。

**现在能填的只有两块**：`params`（14 项 identity 映射，需要 `probe.ruleAliases` 非 null，否则 `_replacementBaseline` 返回空、证明不了任何 identity，得显式写 `scale:1, offset:0`）+ `zones`（head/face/body/legs 四区，几何已合法）。

### 4.4 可执行对接方案（要补什么）

**阶段 A（最小可用：只做 params + zones）**
1. live2d 侧补 `model3.json` 壳 + `.moc3`（或写一个把 `model.json`/`motions.json` 转 Cubism 3 格式的导出器——`model.json` 已有 canvas / layers / bbox / bindings / grid / verts，转换是机械的）。
2. 在 `probe.zonesFrom` 落到 `adapter` 分支后再跑一次，拿 `knownZones`（否则 `zonesFrom=='default'` 时 `_knownZones` 返回空，zones 会被全丢）；填 `params` + `zones`，`emotions`/`actions` 留空，`notes` 写缺证据。
3. 跑 `flutter test test/companion/companion_adapt_test.dart` 验证 `companionAdapterCheck` 不丢关键键。

**阶段 B（完整对接）**
4. live2d 侧产出命名 `exp3.json`（10 情绪至少覆盖 `calm`/`happy`/`sad`/`surprised`/`confused`/`smug`/`sleepy` 中参数可得者）+ 命名 `motion3.json`（12 动作中不由缺参数驱动的：`nod`/`nodSmall`/`shake`/`tilt`/`tiltLeft`/`lookUp`/`recoil`/`sway`/`yawn`/`wave`）。
5. 给这 4 个缺口参数补通道（`ParamEyeSmile` 可由 `eye_L`/`eye_R` 层形变近似、`ParamBrowLAngle/RAngle` 可由 `brow` 层旋转、`ParamBodyAngleY` 可由 `body_base` 纵向位移近似），否则 `happy`/`shy`/`angry`/`worried`/`duck`/`stretch` 永远进 `dropped`。
6. 在 stage.js 侧让 `loadedExpressions`/`loadedMotions` 真填上，并让 App 端 `evidence[name]` 有非空值（否则 `_effects` 过滤掉一切）。

**明确差在哪（一句话）**：live2d 的产物是「程序化参数动画包」，companion-adapt 要的是「带命名表情/动作资源的 Cubism 包 + 参数验证到的 identity 映射」；两者的公共子集只有 14 个参数与 4 个区域。

---

## 5. 验证（实跑记录）

| 检查 | 命令 | 结果 |
|---|---|---|
| `flutter analyze` | `cd app && bash /d/dsh/tools/fl3477.sh analyze --no-fatal-infos` | **`No issues found! (ran in 136.7s)`** |
| 四大适配相关测试（7 文件：`test/chat/voice_focus_test.dart`、`test/agents/agent_teams_state_test.dart`、`test/agents/team_inline_card_test.dart`、`test/voice/voice_mode_state_test.dart`、`test/bots/room_goal_board_test.dart`、`test/bots/bots_goal_board_test.dart`、`test/chat/rows_agent_teams_card_test.dart`） | `cd app && export DSH_TEST_FONT_DIR='D:/dsh/tools/testfonts' && bash /d/dsh/tools/fl3477.sh test <7 files>` | **`00:06 +96: All tests passed!`** |
| companion-adapt 契约测试（`test/companion/companion_adapt_test.dart`、`test/companion/companion_bundled_pack_test.dart`） | `cd app && export DSH_TEST_FONT_DIR='D:/dsh/tools/testfonts' && bash /d/dsh/tools/fl3477.sh test <2 files>` | **`00:03 +18: All tests passed!`**（含 "only what the model backs is kept"、"explicit retained params keep negative affine coefficients and support face on legacy stage"、"kept beside the character written with the moc3 fingerprint"、"fitting on its own: on unless turned off, once per model"） |
| 插件静态检查 | `node sdk/plugin-kit/bin/check.mjs <dir> [--load]` | tavern / live2d / sophia-core **exit 0**；ds-bot **exit 2**（见 §3.1） |
| git 状态 | `git rev-list --left-right --count upstream/main...HEAD` | `0  1` |

**工具链注意（复现须知）**：
- PATH 里没有 `flutter`/`dart`，必须用 `/d/dsh/tools/fl3477.sh`（Flutter 3.47.7 / Dart 3.13.5 / rev `abaf9c5237`）。`/d/dsh/tools/fl.bat` 与 `fl.sh` 指向 flutter-sdk 3.47.9，snapshot 缺失（`Could not find a command named "...flutter_tools.snapshot"`），**已废，别用**。
- widget 测试**必须** `export DSH_TEST_FONT_DIR='D:/dsh/tools/testfonts'`，否则 `test/support/test_fonts.dart:36` 抛 `Bad state: Test font missing: /usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc`，18 个文件全 load 失败。字体三件套在该目录已备齐。

---

## 6. 遗留项

| # | 事项 | 归属 | 说明 |
|---|---|---|---|
| 1 | **ds-bot 宿主加载失败** | 三线（ds-bot） | 三条：补 `engines.dsh`；`@deepseek-ai/dsh-scope` 解析（无 `DSH_DIR` 时 `Cannot find package`）；`ctx.tools.guard is not a function` 需换成本宿主暴露的面 |
| 2 | **dsh-xdpool 全机不存在** | 待确认 | 需确认是已下线还是漏装；无法核对 |
| 3 | **live2d 无 `model3.json`/`.moc3`/命名 expressions/motions** | 二线（live2d，A 组） | §4.4 阶段 A/B 的 6 步；不补则 companion-adapt 只能填 params+zones |
| 4 | **我们 4 插件零 dshGo 清单** | 全员决策项 | 现状「普通插件 + 工具卡」可用；要不要原生卡片/面板需产品决策，不做也能跑 |
| 5 | **branch 未推 origin** | 待授权 | `adapt/upstream-1c5b2200` 仅本地。推 origin 需先确认（本任务边界禁止强推 origin） |
| 6 | **tavern `BOUNDARY-SDK-CONTRACT.md` 与代码不符** | B 组（tavern） | 文档说的 `installFallbackGuard` 兜底、`POST /tavern/api/*` 需自兜、`engines.dsh:"*"` 三条在现存代码上均已解决或不存在；文档该更新（本任务边界不改二线仓库本体） |
| 7 | `.sophia-tmp/`、`app/.sophia-tmp/` 未跟踪 | 清理项 | 都不在 `.gitignore` 内，rebase 未受影响；按需清理或加忽略 |
| 8 | **上游 `runtime/patches` 117 个 .diff** | 长期 | 上游自打补丁层是常规机制，与本 fork 的补丁不撞（本次 rebase 只 1 个冲突）；后续每次同步要复查 `pins.json` |

---

*本报告由 收尾C组（三线适配组长）生成。所有数字来自本机实跑；`/d/dsh/ci-run/dsh-go`（旧 CI 副本，HEAD `4666f9f0`，porcelain 253 行脏）仅作参考，未在其中做任何改动。*
