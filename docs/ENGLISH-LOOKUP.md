# 英文模式：原理与细则

本文讲「打英文 → 出单词 + 中文释义 → 按 Tab 让大模型兜底」这条链路是怎么实现的。
装和用看 [README](../README.md)，多端同步看 [MULTI-DEVICE](MULTI-DEVICE.md)。

## 组成

| 位置 | 角色 |
|---|---|
| `english.schema.yaml` | 独立方案。processors 里挂 4 个 lua，translators 里挂 `table_translator`，filters 里挂 `en_assoc` |
| `dicts/ecdict.dict.yaml`<br>`dicts/chem_ecdict.dict.yaml` | 主词库（Rime 码表格式，单词行权重 10、释义行权重 0） |
| `dicts/ai_ecdict.dict.yaml` | AI 补录的小词库（桥自动写，带 `#v` 版本号） |
| `lua/en_assoc.lua` | **filter**：把释义搬到单词候选右边、跑马灯滚动、必要时补一条单词候选 |
| `lua/en_ai_request.lua` | **processor**：Tab / Ctrl+Enter / Ctrl+Delete / 档位同步 |
| `lua/en_space.lua` | **processor**：选词上屏时补尾随空格 |
| `lua/en_state.lua` | **共享内存**：滚动偏移、完整释义（让按键路径不必读写文件） |
| `scripts/ai_bridge.py` | **常驻桥**：轮询请求文件 → 调 API → 写回词库 + 触发重绘 |

---

## 数据流

```
按键 ─→ speller/table_translator 从码表取：
        info            info   10   ← 单词行（权重 10）
        \x01n. 信息；资料  info   0    ← 释义行（权重 0，文本前有隐形标记）
                              ↓
        filter: en_assoc 认出「单词行 + 紧跟的释义行」：
          释义 → 单词候选的 comment（超宽则按 width 截窗口滚动）
          释义行 → 丢弃
          完整释义 → en_state.set_meaning(word, text)
                              ↓
        候选栏： 1. info  n. 信息；资料
                              ↓
        空格/回车 → en_space 补尾随空格后上屏单词
        Ctrl+Enter → en_ai_request 从 en_state 取完整释义上屏
        Tab       → 见下
```

判定规则只看标记：文本以 `\x01` 开头 = 释义行；文本是纯单词 = 单词候选；
其余（标点、Typst 片段）原样放行 —— 所以标点紧跟词候选时也不会被当成释义。

**这里没有任何查表动作**：`en_assoc` 靠的是"释义行就排在单词行后面"这个布局，权重（quality）只是用来区分两者的辅助线索。所以输入路径上不需要把 7 万词的词表读进 Lua —— 这正是英文模式首次按键不掉帧的原因。

### Tab 的三个分支

`lua/en_ai_request.lua` 里按顺序判断：

1. **释义比窗口宽**（`utf8.len(meaning) > en_ai/width`）→ `en_state.bump(word, tab_step)`，重绘，吃掉 Tab。每按一次向右滚 4 个字（`tab_step`）。
2. **有短释义** → 无事可做，放行给应用（所以在英文模式里 Tab 依然是普通的 Tab）。
3. **本地没有这个词的释义** → 写一次请求文件让桥问 AI（`delay = 0`，立刻发），吃掉 Tab。词长短于 `min_input_len`（默认 2）不发。

早期版本是"停手 900ms 自动发请求"，那要求每次按键都写一次请求文件；现在只有分支 3 会写盘。

---

## 请求/应答文件协议

目录：`%TEMP%\rime_en_ai\`（macOS/Linux 是 `$TMPDIR/rime_en_ai`）

| 文件 | 谁写 | 内容 |
|---|---|---|
| `request.txt` | lua（Tab） | 第 1 行单词、第 2 行停顿毫秒（Tab 固定 `0`）、第 3 行时间戳 |
| `response.txt` | 桥 | 第 1 行单词、其余是释义（filter 在"本地没有候选"时读它） |
| `ai_ecdict.dict.yaml` | 桥 | 追加 `释义<TAB>单词<TAB>0`，并把 `#v` 抬到当前时间戳 |
| `ai_profile.txt` | lua | F4 里选中的 AI 档位（桥据此切换 `active`） |
| `cache.json` | 桥 | 已查过词的完整结果（zh/pos/cap），避免重复付费 |
| `bridge.log` | 桥 | 日志（超过 1MB 轮转） |

桥每 50ms 轮询一次 `request.txt`，所以「按 Tab → 候选出现」的固定延迟约 50ms，其余是 API 时间。

拿到结果后桥做三件事：写 `response.txt`、追加 AI 词库（带新 `#v`）、**注入一次 F24**（lua 收到就重绘候选，所以不用你再敲键）。filter 读到 AI 词库的新 `#v` 才重读那个小文件（≤1 次/秒）。

省钱的四道闸（都在桥里，顺序执行）：

1. 这个词已在 `ai_ecdict.dict.yaml` → 直接回放，不联网
2. 这个词在本地主词库里有释义（`skip_local`）→ 跳过
3. `cache.json` 里已有 → 回放
4. 都没有才调 API

---

## 键位对照（英文模式）

| 键 | 行为 | 实现 |
|---|---|---|
| 空格 / 回车 | 上屏单词 + 一个尾随空格 | `en_space.lua`（F4 里 `no_auto_space` 可关；`en_ai/auto_space: 0` 彻底关） |
| `Ctrl+Enter` | 上屏完整中文释义 | `en_ai_request.lua`（`en_ai/commit_key`） |
| `Ctrl+Delete` | 删掉当前 AI 补录词，收起候选框 | `en_ai_request.lua`（`en_ai/delete_key`；macOS 备选 `delete_key_alt`） |
| `Tab` | 滚动 / 放行 / 问 AI | `en_ai_request.lua`（`en_ai/tab`、`tab_step`、`width`） |
| 左 `Shift` 单击 | 中文 ⇄ 英文模式（切方案） | `mode_switch.lua` |
| 右 `Shift` 单击 | 中文 ⇄ 西文（只切 `ascii_mode`） | `mode_switch.lua`（`en_ai/shift_right: schema` 可改成切方案） |
| `F4` | 选单：自动空格、AI 档位、AI 开关 | schema 的 `switches` |

`Shift` 单击的实现要点：只有"按下又松开、中间没敲别的键"才算单击；松开事件被吃掉，`ascii_composer` 收不到就不会顺手把 `ascii_mode` 也切了。所以按住 Shift 打大写完全不受影响。

`Ctrl+Enter` / `Ctrl+Delete` 里没有 `Ctrl+Shift+A` 之类的 AI 快捷键 —— AI 开关只在 F4 选单里点，避免误触。

---

## 词库怎么生成

```powershell
python scripts\ecdict2dict.py --csv C:\path\to\ecdict.csv `
    --out dicts\ecdict.dict.yaml --chem-out dicts\chem_ecdict.dict.yaml --limit 40000
```

* `--limit` 控制收多少高频词（40000 约 6MB）；`--max-meanings` 控制一个词保留几条释义
* 时态/复数/比较级等变形会一起生成（ECDICT 的 `exchange` 列），释义带「（xx 的变形）」提示
* `[化]` 标记的词条 + 内置的化学常用词表进 `chem_ecdict.dict.yaml`
* 文件头写 `#v<时间戳>`，桥和 lua 都靠它判断"要不要重读"

**大小写**：Rime 的码表查询是精确匹配（`Dictionary::LookupWords` → `prism_->GetValue`），
词库里只有 `hello` 时打 `Hello` 一条候选都没有。这里**不复制词条**，而是用拼写运算派生：

```yaml
# english.schema.yaml
speller:
  alphabet: "…ABCDEFGHIJKLMNOPQRSTUVWXYZ'-"   # 大写必须是合法按键
  algebra:
    - derive/^(.)(.*)$/\u$1$2/               # hello → Hello（派生码，指向同一条词条）
```

`DictCompiler::BuildPrism` 会在建 prism 时读 schema 的 `speller/algebra`（`dict_compiler.cc:310`），
`derive` 用 `boost::regex_replace`（`calculus.cc:127`），replacement 里的 `\u` 是 boost 的大小写转义，
所以派生出来的码和原码指向**同一个 syllable id**：`en.table.bin` 里词条只有一份。

代价与副作用：

* 全大写（`HELLO`）没有规则，查不到 —— 写句子用不到，不处理
* 派生码让 prism 变大（7.4 万码 → 约 15 万键，`en.prism.bin` 2.2M → 6.4M），表反而小了
  （`en.table.bin` 6.0M → 4.2M），查词速度不变
* 候选正文是小写（库里的那份），上屏时 `lua/en_space.lua` 按输入首字母补回大写：
  敲 `Hello` + 空格 → 上屏 `Hello `

---

## 界面

竖排候选（`weasel.custom.yaml` 的 `style/horizontal: false`）下每条候选一行，释义跟在同一行右侧。
长释义不换行，而是按 `en_ai/width`（默认 12 字）开一个窗口滚动显示，按 Tab 前进。

不要用横排：Weasel 的横排布局只有 `max_width > 0` 才换行，而它默认是 0
（`WeaselIPCData.h` 里 `max_width(0)`），一条长释义配五条候选会排成一条超出屏幕的行。

## 为什么非要一个常驻进程

Rime 的 Lua 组件不能联网、不能起定时器、也不能可靠重启输入法进程。所以：

* lua 负责"当场的判断"（哪个键、要不要滚、要不要请求）
* Python 桥负责"慢的、脏的"（HTTP、超时重试、写文件、重新部署、重启输入法、开机自启）

桥是纯增量：不跑它，本地词库和释义全都正常，只是生僻词没有 AI 释义。

## 改完怎么生效

| 改了什么 | 生效方式 |
|---|---|
| `lua/*.lua` | **重启输入法进程**（不是部署！librime-lua 每个引擎会话只 require 一次）。桥盯着文件会自动重启 |
| `*.schema.yaml` / `*.custom.yaml` | 重新部署。桥会自动做 |
| `*.dict.yaml` | 重新部署（AI 词库不用，桥靠 `#v` + F24 让 filter 就地重读） |
| `ai_config.json` | 桥 1 秒内自动重读；档位列表变了会顺带更新 F4 选单并部署 |

手动部署（桥没跑时）：

```powershell
& 'C:\Program Files\Rime\weasel-0.17.4\WeaselDeployer.exe' '/deploy'
```

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| 释义完全不出现 | 不在英文模式（只是 `ascii_mode` 直通），或 `build/en.table.bin` 比源文件旧 → 重新部署 |
| 打 Tab 没反应、也没 AI | 桥没跑（看 `bridge.log`）；或档位缺 `base_url`（日志写「跳过请求」）；或词长 < `min_input_len` |
| AI 一直失败 `WinError 10061` | 端口连不上：API 地址写错、或需要代理 |
| 改了 lua 没生效 | 只部署不够，要重启输入法（桥会自动做） |
| 部署失败 / 反复部署 | `%TEMP%\rime.weasel\*.log`；检查用户目录里有没有名叫 `nul` 的文件（会让 librime 部署抛异常） |
| `Ctrl+Enter` 上屏的是单词 | 高亮的那条没有释义（比如联想出来的词），或者该词释义为空 |

`python scripts\lookup.py typst titration ran` 可以查某个词到底在哪个库里。

## 自测

```bash
bash tests/run.sh                    # 8 个 Lua 组件的行为测试
python scripts/ai_bridge.py --selftest
```

测试用一个假的候选流喂给 filter、用假的请求文件喂给桥，都不需要输入法在跑。
