# Golden 基线判定

golden 差异报出来时，先回答一个问题：这是**代码变了**，还是**换了平台**。这两件事在单机上混在一起，只看一个平台会得出相反结论。本机的做法是三个条件一起测：把同一份基线放进与 CI 同口径的容器、放进本机、再拿旧的基线放进容器。三个读数凑齐才能分开。

## 判据一：不要用单一的 k 描述 AA 差异

灰度抗锯齿的差异不是均匀缩放，所以「整体偏柔化」这句话不能用单个缩放系数表达。

- `k_through_origin` 在 0.9052–0.9294，只说明整体偏向柔化，不能代表每一档。
- 按原始斜率分档测局部增益：小台阶（`|dc| < 0.05`）在 1.047–1.179，大台阶被压到 0.826–0.856，随原始斜率单调递减。
- `median_r` 在低三档恒为 1.000，即半数像素根本不变。这一条比 k 更能防止后来引用的人读反。
- 93–98% 的越过阈值像素三通道同步变化（`corr(dR, dB) ≈ +0.99`）；差异向量的 `σ2/σ1` 为 0.0162–0.0572（秩 1），说明差异集中在一个方向上，不是三通道各走一路。

## 判据二：横向累积位移（advance）这条不成立

「字体 advance 有亚像素差，误差从左到右累积」这个解释直观，但站不住。

判据：用每列 `|grad| > 2` 的像素数作内容量分母，对「差异像素 / 内容量」与列号做回归，归一化后**斜率 ≈ 0、`corr` ≈ 0**，所以没有可测的横向累积。

取样：

| 图 | 斜率 | `corr` | 左 | 右 | 比值 |
| --- | --- | --- | --- | --- | --- |
| `bot_chat_dark` | −0.00008 | −0.197 | 0.2309 | 0.2127 | 0.921 |
| `bot_details_light` | 0.00000 | 0.000 | 0.2864 | 0.2707 | 0.945 |

`bots_home_dark`（比值 0.440）的右侧是大片空白区，内容量分母不稳，不进入这条判据。

不要用「每列差异像素数 vs 列号」的原始斜率来说明任何事——它同时混进了内容分布，而且那个负号方向证不了「不累积」。下一个引用的人会拿它去支持一个它支持不了的结论。

## 判据三：`dsh_ui_dialect` 两张基线必须重录

结论：重录必需，Windows 上剩下的 2.28% 属于平台残差。

| 基线 | 容器（Linux / Flutter 3.47.7，与 CI 同口径） | 本机 Windows |
| --- | --- | --- |
| 旧 `8fb3bc26…` / `60a52654…` | 10.73%，82012px / 82019px，`+0 -2` 失败 | 11.88%，90780px / 90797px |
| 新 `09ae8fab…` / `848cf9ad…` | `00:02 +2: All tests passed!` | 2.28% / 2.29%（17478px / 17489px；另一次测得 17462 / 17476） |

只在 Windows 上跑会误判成「重录了也还是红」；只在容器里跑新基线会误判成「本来就不用重录」。两边都跑才能分开两条结论：旧基线在 Linux 上确实失败 10.73%，所以必须重录；新基线在 Linux 上通过、在 Windows 上还剩 2.28%，那是平台残差。

**重录的合法性来自容器内零差异，不是「反正 Windows 上绿不了」。** 这两件事必须分开：前者是「新基准图与 CI 环境的渲染结果一致」，后者只是「本机通过不了所以不用管本机」。验证方式是拿**提交后要进仓库的那份源码加那两张图**去跑，而不是另找一份等价物：`ci-run/s3` 树上 `goldens/dsh_ui_dialect_{dark,light}.png` 与 `dsh_ui_dialect_golden_test.dart`、`dsh_ui_dialect_genui.dart` 四份文件的 md5 与主树逐位相同（`09ae8fab…` / `848cf9ad…` / `13428faa…` / `b13840d4…`），在这个组合上跑 `flutter test --no-pub test/chat/dsh_ui/dsh_ui_dialect_golden_test.dart` 得 `00:01 +2: All tests passed!`，`failures/` 零产出。源码一致这条是前提——s3 与主树如果源码不同，那个「通过」证的就不是这两张图。

所以提交前不必再在 Windows 上验一遍：Windows 上那 2.28% 本来就是判红的结果，它不是判据。真正要守的是「容器里这套组合零差异、零失败产出」这一条。

两个已排除的方向，不必重跑：

- **不是整像素位移**。穷举 `dy, dx ∈ [−3, 3]`，最优解仍是 `(0, 0)`；按灰度口径该处为 17.35%，其余位移都在 23.89% 以上。
- **旧基线那 10.73% 不是纯 AA 残差**。`|Δ| ≤ 31` 只占 75.5%（另一张图 78.2%），有 12.2%（12.4%）的像素落在 `|Δ| ≥ 192` 档（bin 12 有 4014 / 966 像素）——那是内容级差异。重录前看到的那 2.28% 才是纯 AA 型。

「2.28% 是平台残差、11.88% 是内容差异」这两个数字是两类东西，用一个平坦区占比就能分开，不必再借 SVD 或分档增益：取 `diff > 8` 的像素，看它们落在平坦区还是笔画边缘（`onEdge`）。

| 比较 | `diff > 8` 像素 | 平坦区 | 边缘 |
| --- | --- | --- | --- |
| 新基线 vs Windows 渲染（2.2%） | 13314 | **2.4%**（326px） | **97.0%** |
| 旧基线 vs Windows 渲染（11.88%） | 63101 | **65.3%**（41235px） | **33.1%** |

复算这张表要同时满足三个条件，缺一个就对不上，但**对不上的是绝对数，不是结论**：

1. 灰度取亮度加权 `round(0.299R + 0.587G + 0.114B)`，取整方式也要写死——`round` 与截断会差几个像素。换成三通道均值方向一致但绝对值不同，别混着引。
2. `diff > 8` 用的是同一套亮度差，不是 `maxCh`（我复算 `maxCh > 8` 给 13678 / 64675，与本表不同口径）。
3. 平坦区/边缘的梯度**一律取自新基线这张固定参考图**。两边各取自己的梯度会让旧基线那一行从 65.3% 变成 64.7%（我独立复算是 67.7% 对 64.4%），差的这几个百分点就是「两行的平坦区不是同一块画布区域」。

第 3 条是这张表能成立的原因：固定参考之后，两行的分母落在同一批画布像素上，比较的才是「差异落在哪」而不是「两张图的平坦区各在哪」。

**绝对像素数会随所引用的那次 `testImage` 浮动**——`failures/` 每次运行重写，我的独立复算用的是 22:57 那次（新基线 13483px、平坦区 2.4%；旧基线 63009px、平坦区 67.7%），与表里 22:4x 那次差几十到几百像素。稳定的判据是量级差：**新基线约百分之二、旧基线六成多**，隔着近三十倍。写结论时不要把这几个常数钉死，钉死的是「一个压在笔画边缘、一个摊在平坦区」这个性质。

另外本节出现的 `2.28%` / `11.88%` 与上表不是同一度量：它们按 `maxCh > 0` 计（我复算新基线 17478px 即 2.2865%，与表中 17478px 逐位一致；旧基线 90624px 即 11.8556%）。按亮度 `> 0` 计会略低（2.2726% / 11.8332%）。两个口径混在同一节里，各标一句，读的时候不要当成同一套数。

新基线那 2.28% 几乎全压在笔画边缘（97.0%），是重采样与抗锯齿的固有差；旧基线的差异有 65.3% 摊在平坦区，那不是 AA，是画面上有东西不一样。另外 `d ≥ 128` 的 1039px 里 `onEdge` 占 88.6%，bbox 铺满 `y80–1330 / x33–344`（178 行、215 列散布），是字形边缘的散布而非某块实心矩形——这同时排除了「有元素漏画」。

## 判据四：`bots` / `drawer` 不重录

依据是两条彼此独立的证据并列，容器读数不在此列（原因见下）：

1. CI job 0（`127920473170`，`gh run view 42226267891`）的统计行 `🎉 3086 tests passed, 156 skipped.`，4293 行，统计行在 `:4267`；`grep -c "❌"` 返回 0；其中 `bots_golden_test.dart` 16 条 + `drawer_golden_test.dart` 15 条共 31 条 `✅`。
2. 容器复现的 `+16` 与 md5 汇总 `e86f295e…` 未变。

还有一条历史证据，比「有没有先例」更要紧：**bots 这组基线从来没有被环境驱动重录过。** `git log --all -- app/test/bots/goldens/` 只有两条记录，一条是 `a5fa6738` 导入（png=18），一条是 `8e4bb3a5`（png=8，另加一个 `app/test/motion/stream_fluid_test.dart`）。后者是功能驱动——那个 dart 文件里就是 `expect(swaps, findsNWidgets(3))` 改成 `findsNWidgets(2)`，因为 `ChatHeader` 的 `FluidTextSwap` 从 3 个变成 2 个，页面结构确实变了，所以重录其中 8 张。剩下 10 张自导入起一次都没动过。全仓唯一的「环境驱动重录」是 `6fe52b49`，`git show --name-only 6fe52b49 | grep -c "test/bots"` 返回 0，它只在 12 张 remote 页面上，差异量级是 4–14 像素、`maxD=1`。所以拿「仓库有环境驱动重录的先例」来支持这批 1.2%–2.4% 的重录，成立不了：两者差三个数量级，而且那个先例压根没碰过 bots。

第 1 条能覆盖这 31 条，靠的是一个**分片巧合**，不是结构保证，写结论时必须知道它什么时候失效。`ci.yml` 的「Test every third file」那步是 `find test -name '*_test.dart' | sort | awk 'NR % 3 == ${{ matrix.shard }}'`，`NR` 从 1 起、没有 `-1`。

先固定证据属于哪棵树。那个 run 的 `gh run view 42226267891 --json headSha` 是 `4e1665eb4b96b785c3e01efea40679a906ba5c8c`，比当前 HEAD `4666f9f0` 落后 3 个 commit。实测 `4e1665eb` 与 `4666f9f0` 两棵树的测试文件数都是 863、两条 golden 位置都是 36 与 276，所以那 3 个 commit 没影响结论；但**写「HEAD 树」是错的**——HEAD 一前进，这行就没法判断还成不成立。口径应写成「证据 run 的 `headSha` 树」。

| 口径 | 文件数 | `bots_golden_test.dart` | `drawer_golden_test.dart` | 差值 `%3` |
| --- | --- | --- | --- | --- |
| 证据 run 的 `headSha` `4e1665eb` 树（= `4666f9f0` 树） | 863 | 36 → shard 0 | 276 → shard 0 | 240 → 0 |
| 工作树（含 `app/` 下 7 个未跟踪 `*_test.dart`） | 870 | 39 → shard 0 | 282 → shard 0 | 243 → 0 |

7 是 `app/` 口径（863+7=870）。从仓库根数 `git status` 会得到 **10** 个未跟踪 `*_test.dart`：另 3 个在 `packages/dsh_client/test/`（`agent_teams_api_test.dart`、`dsbot_goal_test.dart`、`voice_mode_api_test.dart`），它们走 `dart test` 那个 job、不参与分片，不影响这 31 条，但对账时容易以为是数错了。

**CI 用的是提交进去的树，不是工作树**——引用这 31 条要按 863 那行的位置，未提交的测试文件当时并不在 CI 视野里。

还有一个比数字更硬的补充：这 31 张图从证据 run 到现在**一个字节都没变**。`4e1665eb` 树与工作树的 `app/test/{bots,drawer}/goldens/*.png` 逐张比对是 33 张全同、没有一张不同、也没有一张缺失（`SAME=33`，另两类为空），两个测试源码的 blob hash 也相同（`bots_golden_test.dart` 均为 `f2ff99f3…`，`drawer_golden_test.dart` 均为 `2d63c69a…`）。所以「job 0 覆盖 31 条」今天仍能当活证据引用，不是只在某次运行里成立的旧说法。

两条同片的条件只有一条：位置差能被 3 整除。工作树这次同片，是因为 `282 - 39` 得 243，而 243 恰好是 81 个 3 —— **这是一个算术巧合，不是结构保证**。文件总数一变、或者有文件插进这两条之间的位置，差值就变，同片关系随时断。所以「永远同片」这个说法是错的，正确说法是「在当前这棵树、当前这个文件集合下同片」。

因此「新增测试文件会让两条一起平移」只对**在 `bots_golden` 之前插入**成立——`test/agents/` 排在 `test/bots/` 前面，两边都加一，`%3` 同向移动；但插在 `test/chat/`、`test/drawer/`、`test/voice/` 这些排在 `bots_golden` 之后的目录，就只有 `drawer_golden` 往下挪一位：

- 在两者之间插 1 个（`test/bots/zzz_probe_test.dart`）→ bots 仍 39/0、drawer 变 283/1，**当场分片**。
- 在 bots 之前插 1 个（`test/agents/aaa_probe_test.dart`）→ bots 40/1、drawer 283/1，仍同片，但整组从 shard 0 挪到 shard 1，**「job 0 通过」这个具体 job 号就失效了**。

工作树此刻还有 3 个未跟踪的 `*_test.dart` 正落在 39 与 282 之间（`test/bots/room_goal_board_test.dart` 66、`test/chat/dsh_ui/dsh_ui_dialect_genui_tap_test.dart` 132、`test/chat/rows_agent_teams_card_test.dart` 190）。它们已经算在 870 里，所以现在仍同片；但只要提交时少掉其中任意一个、或者再补一个落在这个区间的新文件，两条就会被拆到不同 shard。

所以阶段 4 一旦往 `test/bots/`、`test/chat/` 这类落在两条之间的目录加测试，必须重跑一次位置复算，不能沿用「31 条都在 job 0」这句话：

```sh
cd app && find test -name '*_test.dart' | LC_ALL=C sort \
  | awk '{print NR"\t"NR%3"\t"$0}' \
  | grep -E "bots_golden_test|drawer_golden_test"
```

两个 `%3` 不相等，就说明两条落在不同 shard，得分别去两片取证据。

**不能**把那批容器读数当作「CI 口径也通过」的证据。它只说明一件事：机器上没有彩色 emoji 字体时，两个平台渲染一致。`app/test/drawer/support.dart:67` 是 `if (!file.existsSync()) return;`，字体缺失时静默返回，所以差异全部落在放 emoji 的那一小块区域，落在别处则没有差异——这恰好排除了 emoji，却也说明这份读数只覆盖了一个很窄的面。

这一步有个必踩的坑：`loadEmojiFont` 认的是**固定绝对路径** `/usr/share/fonts/noto/NotoColorEmoji.ttf`，文件名和目录都必须逐字如此。Debian 的 `fonts-noto-color-emoji` 装在 `/usr/share/fonts/truetype/noto/`，与代码读的这处不是同一个目录；而 `/usr/share/fonts/noto/` 在干净镜像里根本不存在，照上面照抄 `cp` 过去会先报 `No such file or directory`。要写成 `sudo install -Dm644 <源> /usr/share/fonts/noto/NotoColorEmoji.ttf`（`-D` 就是负责建目录的那一半，不是可选写法），或者先 `mkdir -p`。工作流自己也是这么写的，见 `.github/workflows/ci.yml:147`。把它挂在旁边的路径或换个名字，`existsSync()` 就判为不存在，静默返回，什么都不生效——同一次单变量对照里，同一份源字节换个文件名，差异就从内容级降到极小残余。所以复现时要检查这一行，而不是去比对 sha256：**版本差不改变它与 CI 的判定结果——两者都红**，因为零容差在 `_goldens_io.dart:237`（该处逻辑是「差值非零即判失败」）；它只改变差异的量级（内容级 8604 / 8614 → 残余数十至一千余像素）。要零差仍然只能装 CI pin 的 v2.051，见本节下面那段。

同一个 run 的边界，写结论时必须带上：

- `Flutter 1`（job `127920473047`）**没有总结行**，3571 行止于 `runtime_logs_test.dart` 的一个 `##[group]`；`❌` 计数为空只表示没跑完，不是全部通过。
- `Flutter 2`（job `127920472970`）是 `3364 tests passed, 8 failed, 108 skipped`，那 8 条才是真红。

所以这套 run 只能得出一个结论：job 0 通过。也不要拿「另外两个 job 也没有失败标记」当补充——它们一个没跑完、一个有 8 条真红。另外不要用日志里出现过的文件名数来估覆盖率：`--reporter github` 只打印有输出的文件，唯一可靠的口径是最后那行统计。

只说「drawer 15 条 ✅」会漏掉它的适用范围：那是 **Linux / job 0 口径**。在本机 Windows 上原样复跑，`test/drawer/drawer_golden_test.dart` 会 `00:22 +0 -15` —— 15 张全红、0 通过，而且不是只红含 emoji 的那两张，因为 `File('/usr/share/fonts/noto/NotoColorEmoji.ttf')` 这个 POSIX 绝对路径在 Windows 上恒不存在。**所以 drawer golden 不能当 Windows 侧的证据。**

同一棵树里字体加载有两套相反的策略，这决定了两种失败的形态完全不同：

- `app/test/support/test_fonts.dart:34-38` 是 `if (!file.existsSync()) { throw StateError('Test font missing: $path'); }` —— 缺字即炸，严格。
- `app/test/drawer/support.dart:66-67` 是 `if (!file.existsSync()) return;` —— 缺文件直接返回，静默。

因此「测试通过就说明字体在位」只对 CJK 成立，对 emoji 完全不成立：drawer 那 15 张在缺 emoji 时不报错，只会把 emoji 画成方框再被判红。要判 emoji 是否真加载了，看 `failures/` 有没有产出，不要看退出码。

**drawer 的 15 条和 bots 的 16 条必须分两句写，不能合成「31 张在 Windows 上全红」。** drawer 那 15 条全红，是因为 `setUpAll(loadEmojiFont)` 在 `main()` 顶部，7 个 `goldenBoth(` 各出 dark+light 两条（14）加 1 条独立 `testWidgets`，15 条全在它之后，字体静默失败后无一幸免——这个数目是测试结构算出来的，与 `goldens/*.png` 的 15 个文件也对得上，比单次日志的 `+0 -15` 更抗质疑。bots 那 16 条走的是另一条路：`app/test/bots/bots_golden_test.dart:36` 是 `await tester.runAsync(loadGoldenFonts)`，全文件 `grep emoji` 为空，根本不碰 `loadEmojiFont`，所以 emoji 字体在不在对它们没有影响；它们在 Windows 上照样是 `+0 -16` 全红，但失败形态完全不同——逐条都是 `Pixel test failed`（`1.19%` / `0.76%` / `2.38%` 这种），`grep -E "StateError|Test font missing"` 零条。也就是说 bots 那边字体是齐的（`DSH_TEST_FONT_DIR` 指向真 ttcf），红的原因是平台光栅化残差；drawer 那边是缺 emoji 画成方框。**两者在 Windows 上都红，红的机制不是一个。**

drawer 那 15 张里，真正依赖 emoji 字形的只有一张，这一点可以用平坦区占比单独判出来，不必比哪台机器红了几条。Windows 复跑（真 ttcf）留下的一批产物（`app/test/drawer/failures/`，`22:45`，60 个文件）逐张按同一套算法算：

| 用例 | 差异像素（`maxCh > 0`） | 占比 | 平坦区 | 中间档 | 边缘 |
| --- | --- | --- | --- | --- | --- |
| `drawer_g9_empty_dark` | 9709 | 0.7374% | 0.56% | 0.00% | 99.44% |
| `drawer_g9_filter_dark` | 14590 | 1.1081% | 0.77% | 0.00% | 99.23% |
| `drawer_g9_folders_dark` | 28741 | 2.1829% | 0.88% | 0.00% | 99.11% |
| `drawer_g9_folder_editor_dark` | 38080 | 2.8922% | **27.44%** | 0.34% | 72.22% |

前两列（差异像素与占比）换人复算能逐位对上，而且不依赖任何算子选择。后三列不能照抄：**它们取决于灰度口径、梯度算子和平坦/边缘两个阈值，换一套就是另一排数**。上表这一套写死才可复现——灰度取亮度加权 `0.299R+0.587G+0.114B`，梯度取 `max(|gx|, |gy|)` 的 `np.gradient` 中心差分，掩膜为 `maxCh > 0`，分桶为 `g ≤ 1` / `1 < g ≤ 2` / `g > 2` 三档。

**中间档必须单列，不能并进任何一边。** 早先有一版把这张表写成「平坦区 / 边缘」两列，两列相加不到 100%——那是把中间档各自分摊后再四舍五入的结果，换个算子复算就对不上，已撤掉。三档分列之后每行和恒为 100%，谁都能验。

**能钉死的性质不是那几个百分数，是排序与量级差。** 同一套三分桶、只换梯度算子：`sqrt(gx²+gy²)` 给出 `0.56 / 0.77 / 0.88 / 27.44`（与 `max(|gx|,|gy|)` 逐位相同，因为平坦区的判定落在 `≤1`、两种幅值在这一档没有分歧）；Sobel（÷4 归一）给出 `0.11 / 0.28 / 0.33 / 25.91`，前三个用例被压掉一个档，`folder_editor` 仍在 26% 上下，与它们差两个数量级。换差分方向则把区分度压掉一大截：前向差分给 `6.04 / 10.11 / 14.30 / 36.92`，`folder_editor` 对 `folders` 只剩 2.6 倍（中心差分是 31 倍）；后向差分给 `16.03 / 13.34 / 11.08 / 37.44`，四张几乎不分先后。**所以「排序」这句话只在中心差分族里稳，「差几个数量级」也只在 `max(|gx|,|gy|)`/`hypot`/Sobel 下成立。** 差分方向一变，前向/后向在平滑区分别低估与高估梯度，排序本身就塌掉了。

这就把「哪一张真的依赖 emoji」钉住了：空抽屉、筛选、文件夹这三张的差异几乎全落在笔画边缘，是平台文字光栅化的残差；只有 `folder_editor` 有可观的一块差异摊在平坦区——那是 emoji 被画成 tofu 方块，不是抗锯齿能解释的量级。反过来说，`drawer_g9_empty` 在 Windows 上 0.7374% 也红，正说明「Windows 红」这件事在**不含 emoji 的图上照样成立**，emoji 路径只是叠加在它上面的第二个因子。

drawer 那 15 条因此在三个不同的环境里给出三个不同的读数，**这三个数不能压成一句话**：

| 环境 | 结果 | 差的到底是什么 |
| --- | --- | --- |
| Linux · emoji 路径正确（带 emoji 的镜像） | `+13 -2` | 那 2 条是 Debian 版与 v2.051 的字形版本差（**非 AA 性质**），零容差所以仍红 |
| Linux · emoji 路径不对（干净镜像） | `+0 -15` | emoji 画成 tofu，`folder_editor` 到 8604px / `maxD` 240 |
| Windows · 任何字体 | `+0 -15` | 14 张纯平台 AA，`folder_editor` 再叠一层 tofu |

只有第一行是「接近通过」，另两行都是 15 条全红但原因不同：中间那行是缺字体，最后一行是平台。CI 是第四种情形——它装 CI pin 的 v2.051 到正确路径，所以 job 0 里这 15 条全过。把它们混成「drawer 在容器里 13 绿、在 Windows 上 15 红」会丢掉「路径对不对」这一维，而那一维才是 `folder_editor` 那张 3.20% 里 3.10 个百分点的来源。

「Windows 上的 1.2%–2.4% 来自平台」这句话还需要一格实验才成立：得证明它不是 Flutter 修订号造成的。这一格已经跑完了——Windows 上换 Flutter 3.47.7（`abaf9c5237` / Engine `deb287481e`）跑 `bots_golden_test.dart`，结果与 3.47.9（`c197ca5199`）**逐张一致**：`+0 -16`，逐条百分比与像素数一个数不差；两版本渲染出的 16 张 `testImage.png` 用 `md5sum` 逐对比是 **16 SAME / 0 DIFF**。

所以变量落在平台，不在引擎修订号；`Linux + 3.47.9` 那一格不必再跑，跑出来也只会是 0 差。三行表可以这样读：

| 平台 | 字体 | bots 16 张 |
| --- | --- | --- |
| Linux x64 · 3.47.7（标定环境） | CI pin 的真 ttcf | `+16 All tests passed!` |
| Linux x64 · 3.47.7 | 本机损坏的 ttc | 12 张以上转红 |
| Windows · 3.47.9 | 真 ttcf | `+0 -16`，1.2%–2.4% |
| Windows · 3.47.7 | 真 ttcf | `+0 -16`，与上行逐张相同的数 |

第二行与第三行各固定一个变量。**平台这一行才是「从 1.5% 直接归零」的跳变，字体那一行只摆动零点零几个百分点。** 但要注意字体在 Linux 上并非无关：缺 Light 字重会让 w300 文字变粗，12 张以上转红就是它造成的；只是它的量级在 Windows 上不显现。

还有一处入口容易误判：`DSH_TEST_FONT_DIR` 全仓只有 `app/test/support/test_fonts.dart:51` 这一处读它，`drawer/support.dart` 完全不读。所以改这个变量对 drawer 那 15 张**无效**，即使它指向正确的 CJK 目录也照样全红。真要在 Windows 上复现，只有两条路：按 `/usr/share/fonts/noto/NotoColorEmoji.ttf` 这个绝对路径把文件放上去（含建目录），或者新增一个专用变量由 `drawer/support.dart` 自己读——现在没有这个口子。注入时族名还必须仍是 `Noto Color Emoji`（`app/lib/ui/shell/drawer/folder_mark.dart:16` `const emojiFontFallback = ['Noto Color Emoji'];`），族名差一个字符也等于没注入。

`failures/` 目录另有一个陷阱：`git status` 干净不等于盘上干净，而且**判断当前基线永远只看 `goldens/`**——`failures/` 里的 `*_masterImage.png` 是某次失败当时的**输入快照**，不是基线。`app/test/chat/dsh_ui/failures/` 被 `.gitignore:21` 的 `**/test/**/failures/` 忽略，0 个跟踪文件，所以「git 干净」是真的，盘上留着的旧快照却看不出来。重录前那批留下过 `dsh_ui_dialect_dark_masterImage.png` md5 为 `8fb3bc26…`，与当前基线 `09ae8fab…` 不同，拿它当「当前基线」去比会凭空算出 10.6% 的假差异。要确认基线只认：

```sh
md5sum app/test/chat/dsh_ui/goldens/dsh_ui_dialect_{dark,light}.png
```

这批残留还顺带给出了一条比退出码更硬的证据。容器那次失败运行时盘上装的还是旧基线，产物里 `testImage`（实际渲染）与旧基线差 `diff>0` 的像素是 82012 / 82019（10.7289% / 10.7299%），而与新基线**逐字节相同（0.0000%）**。所以「新基线 = Linux 渲染结果」不是从 `All tests passed!` 反推的，是像素级对齐出来的。

清残留要分清在哪个树：fork 工作树里 dialect 那 8 个已经删干净（`failures/` 剩 32 个，8 对 `masterImage` 与当前基线逐字节相同）；`D:/dsh/ci-run/dsh-go` 那棵容器树里还留着 8 个（`failures/` 共 40 个，时间戳 `20:42:29`），它是共享挂载副本，要清理得单独说。

## 已撤回的读数

早期有一批按到达笔画边界的距离分档的读数，全部撤回，不要引用，也不要复述它的数字。这类问题只保留一个可复算的口径：`dsh_ui_content_dark.png` 上取该图灰度的众数作背景（`bg` = 56），`a > bg + 20` 为 **3.36%**。

这一节只剩上面那一个数可以引用。凡是在这张图之外出现的「`a > bg` 比例」或「某个区间」的说法，都不要再复述——它们或是把「有的图接近零」和「这张图是 3.4%」拼成了一个区间，或是把某次别的掩膜定义下的读数当成了这张图的值。扫全部 1005 张 goldens 验证过：`a > bg` 落在 34.4%–36.4% 的有 17 张，其中 `a > bg + 20` 最小的是 `0.00%`，没有任何一张图能同时给出一个「高频区间」式的两个数。

引用这批比较时，不要给绝对像素数——掩膜一改就漂 2%–5%，写进文档等于留隐患。只用比值和相关系数：

| 判据 | 取值 |
| --- | --- |
| `any/all3` | 0.9330 / 0.9720 / 0.9759 |
| `corr(dR, dB)` | +0.9942 / +0.9925 / +0.9983 |
| SVD `σ2/σ1` | 0.0572 / 0.0450 / 0.0243 / 0.0162 |

`σ2/σ1` 这条最硬：量级只要到 0.5，就说明差异不在一维上，也就不是抗锯齿能解释的。

## 复现命令

```sh
# 容器（CI 口径）
docker run --rm -v "$PWD:/w" -w /w/app -e DSH_TEST_FONT_DIR=/fonts dshgo-ci:probe \
  flutter test --no-pub test/chat/dsh_ui/dsh_ui_dialect_golden_test.dart

# 本机：字体目录三选一均可，dialect 这组在三个目录上给出同一读数，
#   realnoto    → 2.28% / 17462px、2.29% / 17476px
#   cifonts/ci  → 2.28% / 17462px、2.29% / 17476px（与 realnoto 逐 px 相同）
#   testfonts   → 2.29% / 17478px、2.29% / 17489px（小号 ttc，Light 与 Regular 同字节）
# 没有哪个目录是「正确的那一个」：这组的本机读数与字体目录无关，指向的是平台。
DSH_TEST_FONT_DIR=<上述任一目录> \
  flutter test --no-pub test/chat/dsh_ui/dsh_ui_dialect_golden_test.dart

# 基线字节
md5sum app/test/chat/dsh_ui/goldens/dsh_ui_dialect_{dark,light}.png

# 彩色 emoji：路径与文件名都必须逐字如此，别的名字一律被当作不存在
# 目标目录在干净镜像里不存在，必须用 install -D 建目录；直接 cp 会报 No such file or directory
sudo install -Dm644 /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf \
  /usr/share/fonts/noto/NotoColorEmoji.ttf
docker exec <container> test -f /usr/share/fonts/noto/NotoColorEmoji.ttf && echo present
```

字体目录的要求见 [Native image galleries](image-gallery.md) 里关于 `DSH_TEST_FONT_DIR` 的那一段。分清两件事：字体的**存在性**不是小变量——它决定 emoji 画成彩色字形还是 tofu，是内容级差异；字体的**版本**（本机 Debian 版 vs CI pin 的 v2.051）只改变差异量级，不改变判定结果——两者都判红。而宿主平台仍然是这些差异里的主导变量，不能靠换字体追平容器读数。

绕开一个容易读反的地方：把 emoji 字体装对**不等于**容器里 drawer 那两张会变绿。实测把 Debian 版（`93cdc4ee…`）装到位后，`drawer_g9_folder_editor_{dark,light}` 仍红，只是差异从内容级 8604 / 8614 像素（0.6535% / 0.6542%，bbox `y[1410,1446] x[78,705]`）降到极小残余（**字形版本差，非 AA 性质**）。这两个 `maxD` 必须带上图才能读：tofu 那张（`66117402…`，emoji 一个都没画出来）按四通道求和是 **240 / 249**；装对字体之后，同一算法是 **16**，按单通道算是 **10**。把 240 和 16 当成同一张图上的「倒退」是读错了——它们是两张不同的图。前面那个极小残余（75 / 95）也不是 AA 残差的下限——同一族、同族名、不同 v2.051 的字形轮廓，落在那个像素数量级是必然的；这说明容器里要零差还得是 CI pin 的那个版本：

```sh
# .github/workflows/ci.yml 三处：:104 版本 pin（NOTO_EMOJI_VERSION: v2.051）、
# :117 注释「The goldens have Noto Color Emoji 2.051; Ubuntu's 2.047 draws the glyphs differently.」、
# :136-137 curl 拉取 + sha256 校验（:135 是 CJK 的 cp，不是 emoji）
curl -fsSL --retry 3 -o ~/test-fonts/NotoColorEmoji.ttf \
  "https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.051/fonts/NotoColorEmoji.ttf"
echo "72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b  $HOME/test-fonts/NotoColorEmoji.ttf" | sha256sum -c -
```

两张 `masterImage` 与现存 golden 逐字节相同（`abe1aa21` / `c02af2dc`），所以红的不是基线而是环境。零容差也在 SDK 里，不在项目里：`packages/flutter_test/lib/src/_goldens_io.dart:231` 累加各通道绝对差得到 `diffPixel`，`:237` 只要该值非零就判失败；项目没有覆盖 `goldenFileComparator`（唯一提到它的是 `app/test/support/english_preview.dart:25` 的 `_PreviewComparator`，那个不改容差）。

那个极小残余的两个像素数并不矛盾，**它们是同一张图的两种数法**。产物 md5 `a4e00a10…`（`ci-run` 树 22:27 那次，输入是镜像内建的 Debian emoji `93cdc4ee…`）：

| 口径 | dark | light | 读它有什么用 |
| --- | --- | --- | --- |
| 任一通道差值非零（累加 RGBA） | **1367** | **1406** | Flutter 判红就认这一列（`diffPixel` 非零即失败） |
| 亮度差 `> 8`（`round(0.299R+0.587G+0.114B)`） | **0** | **0** | 残余像素的亮度差全部 ≤ 8，落在肉眼不可分辨的区间 |
| 三通道 maxΔ > 2 | 75 | 95 | 自定义阈值，只用于「残余有多小」的叙述 |

**`luma > 8` 那一行的读数是零，它比 1367 更值得引用。** 它说明这 1367 / 1406 个像素不是「AA 级差异」这种量级描述，而是每一个都落在亮度分辨不出的一级里；把 `maxD` 写成 10（单通道）或 16（四通道求和）都不会改变这个判断。75 / 95 只是 `maxΔ > 2` 那一种数法，比值 5.49% / 6.76%，不能用来判红绿——`maxΔ > 2` 筛掉的正是只差 1–2 的边缘像素。

`maxD` 的算法也必须在同一段里写清，否则两个数会再打一次架：按单通道算是 dark **10**，按四通道求和算是 **16**。早先把 618 / 654 当 `maxD` 是错的，那是在**tofu 图**（`66117402…`）上按四通道求和的结果，与装对字体后的图不是同一张。

**引用 `failures/` 里的任何数字都必须连 md5 和时刻一起写，并且另留一份副本。** 那个目录是共享的，会被并发的运行覆盖：`ci-run/dsh-go/app/test/drawer/failures/` 在 22:27:39 是 `a4e00a10…`（装对 emoji），22:36:45 已被覆盖回 `66117402…`（无 emoji）。所以只连 md5 一起写还不够——md5 只能证明「说的是哪张图」，不能保证那张图还在。`a4e00a10…` 之所以现在仍可复算，是因为 `ci-run/s3` 那棵树没被并发跑覆盖（`11-07_23:32:09`，`app/test/drawer/failures/` 下 8 个文件）。**先复制产物、再量，或者到不会被覆盖的树里去量。**

**这条读数是可重造的，不必依赖任何人的一次性观测。** 重造方式就是把 Debian 版 `install -Dm644` 到那个固定路径，再跑一次：

```sh
install -Dm644 /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf /usr/share/fonts/noto/NotoColorEmoji.ttf
cd app && flutter test --no-pub test/drawer/drawer_golden_test.dart
md5sum test/drawer/failures/drawer_g9_folder_editor_{dark,light}_testImage.png
```

产物就是 `a4e00a10…`（重造后先 `cp` 一份到不会被并发跑覆盖的树里再量）。独立副本可到 `ci-run/s3/app/test/drawer/failures/` 取，md5 逐位相同：dark `a4e00a10fc85f43f3e0878bb0404b04c`、light `34282b5dd8ca89bd1faf9ebd35977a1a`。三种口径读出来分别是 1367 / 1406、`luma > 8` 两者皆零、75 / 95。反过来的对照也在同一棵树上：tofu 那张（`66117402…`）两种口径几乎重合（99.38% / 99.40%），因为字形差得远时每个差异像素的幅度都大；而版本差那张，差异几乎全是只差 1–2 的 AA 边缘像素，`maxΔ > 2` 一下筛掉 94%。两张图的比值差两个数量级，这正好说明 1367 与 75 是同一现象在不同阈值下的读法，不是环境不一致。

结论部分**只把性质写死、不把常数写死**：字形存在性差 = 内容级 8604 / 8614（A 组 `66117402…`，可独立复算）；字形版本差 = 极小残余（1367 / 1406 个像素，但亮度差全部 ≤8，`luma > 8` 一个都没有）；要零差必须 CI pin 的 v2.051。
