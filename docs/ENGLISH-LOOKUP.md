# 英文模式（本地 ECDICT + 自定义大模型 API）

## 组成

| 文件 | 作用 |
|---|---|
| `english.schema.yaml` | 独立方案：`speller/alphabet` 只有 a–z、`'`、`-`，**没有双拼 algebra**，所以英文码不会被中文方案改写 |
| `dicts/ecdict.dict.yaml` | **基础词库 1/2**：4 万高频词 + 时态/复数/比较级变形，由 `scripts/ecdict2dict.py` 从 ECDICT 生成 |
| `dicts/chem_ecdict.dict.yaml` | **基础词库 2/2 · 化学**：ECDICT 里 1.6 万条 `[化]` 词条 + 一批实验常用词（`titrate`/`esterify`…），通过 `ecdict.dict.yaml` 的 `import_tables` 合并进来 |
| `dicts/ai_ecdict.dict.yaml` | AI 补录（**唯一可删的**：`Ctrl+Delete` 只动它） |
| `lua/en_ai_request.lua` | processor：每次输入变化把单词写进 `request.txt`；收到 `F24` 时重绘候选 |
| `lua/en_ai_candidate.lua` | translator：读 `response.txt`，命中就补一条 `[AI]` 候选（带缓存） |
| `scripts/ecdict2dict.py` | ECDICT csv → 词库 |
| `scripts/ai_bridge.py` | 桥接进程：监听请求文件的**静默期**，到点调 API，写回结果并注入 F24 |
| `test_en_ai.lua` | 上面两个 lua 的离线回归测试 |

候选顺序：**英文原词 → 本地释义（可选中插入中文）→ `[AI]` 摘要**。本地命中 ID 时不会发网络请求。

## 候选长什么样

只有一种显示方式（原来的"查词/联想"两套已经合并）：

```
打 hello →
  hello          interj. 喂；嘿        ← 空格上屏单词
  help           v. 帮助；有助于        ← 联想词，各自带释义
  held           v. 握住；举行
打 information（释义 21 字，超过窗口 12 字）→
  information    n. 消息；知识；通…      ← 按 Tab 滚动看全
```

| 键 | 作用 |
|---|---|
| 空格 / 回车 | 上屏英文单词 |
| `Ctrl+Enter` | 上屏**当前高亮候选的释义**（就是尾部那串中文） |
| `Ctrl+Delete` | 删掉这个 AI 补录的词（基库 ECDICT 的词不受影响），删完候选框收起 |
| `Tab` | 释义超宽时往前滚 4 个字 |
| `Ctrl+Shift+A` | AI 开关 |
| `F4` / `Ctrl+Shift+E` / `` Ctrl+` `` | 方案选单 |

## 使用

```text
F4（或 `Ctrl+Shift+E` / `` Ctrl+` ``）选「英文模式」
输入 comp  → computer / complete / company …（注释里显示 ~uter 这样的剩余字母提示）
输入 hello → hello（英文原词） / interj. 喂, 嘿 …
停手 900ms → 多出一条 [AI] 候选
Ctrl+Shift+A 开关 AI
```

## 两层词库（AI 的单独放一个文件）

| 文件 | 内容 | 谁写 |
|---|---|---|
| `ecdict.dict.yaml` | ECDICT 基库，2 万高频词 | `scripts/ecdict2dict.py` 生成，别手改 |
| `ai_ecdict.dict.yaml` | **只有 AI 补录的词**，一眼能看完 | `scripts/import_saved.py` 追加 |
| `<tmp>\rime_en_ai\*.txt/tsv` | 运行时状态：请求、响应、滚动偏移、候选释义表 | 桥和 lua 自己维护，别手改 |

合库靠 rime 的 `packs`，部署时会把 `ai_ecdict` 编译成附加表跟基库一起查：

```yaml
translator:
  dictionary: ecdict
  packs:
    - ai_ecdict
```

部署日志里能看到 `rebuilding pack 'ai_ecdict'`，产物是 `build/ai_ecdict.table.bin`。
AI 补录过的词也会被桥当成"本地已有"，不再花钱问 API。

### 三个词库的分工

| 词库 | 内容 | 能不能删 |
|---|---|---|
| `dicts/ecdict.dict.yaml` | 4 万高频词 + 变形（`ran`/`bigger`/`titrated`…） | 不能（重新生成即可） |
| `dicts/chem_ecdict.dict.yaml` | 化学专用：1.6 万条 `[化]` 词条 + 实验常用词 | 不能（同上） |
| `dicts/ai_ecdict.dict.yaml` | AI 补录 | **能**，`Ctrl+Delete` 只删这个 |

重新生成（会同时更新化学词库、时态变形）：

```powershell
python scripts\ecdict2dict.py --csv ...\ecdict.csv --out dicts\ecdict.dict.yaml --chem-out dicts\chem_ecdict.dict.yaml --limit 40000
```

桥看到 `*.dict.yaml` 变了会自动重新部署（`ai_ecdict.dict.yaml` 除外，那个是桥自己写的）。

### AI 词库：全自动写入，不用脚本也不用部署

```
英文模式打词 → 桥调 API → 立刻写进 ai_ecdict.dict.yaml（带 #v<时间戳> 版本标记）
                          ↓
              lua/en_ai_candidate.lua 发现版本变了就重读 → 候选里马上能查到
```

- 是**同一个文件**既给人看、又给输入法查，没有中间缓冲、没有合并脚本、不需要重新部署。
- 想删某个 AI 词：直接删掉那几行（`#v` 那行别动，或让桥下次自动重写）。
- 桥下一次查同一个词时，会先在 `ai_ecdict.dict.yaml` 里命中 → 直接回放，不再花钱。
- `ecdict.dict.yaml`（ECDICT 基库）永远不被 AI 改动。

每个词写入 2~4 行（`cap=1` 才有大写版本）：

```
typst                                  typst   10
n. 一种基于 Rust 的现代排版系统与标记语言   typst   0
Typst                                  Typst   10
n. 一种基于 Rust 的现代排版系统与标记语言   Typst   0
```

查看两个库里有没有某个词：

```powershell
python scripts\lookup.py typst hello
```

## 词库怎么改

```bash
python3 scripts/ecdict2dict.py --csv ../ecdict.csv --out ecdict.dict.yaml --limit 20000
# 想收全量（构建会变慢）：--limit 100000；每词释义条数：--max-meanings 3
```

- 只收小写、`^[a-z][a-z'-]*$` 的词；带空格/大写的条目会被跳过（**大写开头的词查不到，会当普通英文上屏**）。
- 每条 `英文原词` 权重 10、释义 0，所以原词永远排第一，空格 = 上屏英文。
- 想加自己的词条：直接往 `ecdict.dict.yaml` 末尾加 `释义<TAB>word<TAB>0`，重新部署即可。

## 大模型怎么接进来的（整条链路）

```
你打字
  │  lua/en_ai_request.lua（processor）
  │  每次 input 变化写一次 <tmp>/rime_en_ai/request.txt   ← 只写文件，不联网
  ▼
scripts/ai_bridge.py（常驻 Python，纯标准库）
  │  盯着 request.txt；内容稳定 delay_ms 毫秒（=你停手了）才动手
  │  ① 词在本地词库里？→ 跳过（skip_local）
  │  ② 缓存里查过？    → 直接回放（cache.json）
  │  ③ 都没有         → POST 你的 API
  │  写 response.txt（第 1 行单词，其余译文）
  │  注入一个 F24 假按键
  ▼
lua/en_ai_request.lua 收到 F24 → refresh_non_confirmed_composition()
  ▼
lua/en_ai_candidate.lua（translator）读 response.txt → 补一条 [AI] 候选
```

配置文件（**放仓库外**，避免 key 进 git）：

```
Windows     : %LOCALAPPDATA%\rime-en-ai\config.json
macOS/Linux : ~/Library/Rime/ai_config.json
旧位置      : %LOCALAPPDATA%\\rime-en-ai\\config.json（启动时自动迁移）
```

### 多个 AI，随时切换

`config.json` 支持多档，`active` 指当前用哪个：

```json
{
  "active": "minimax",
  "profiles": {
    "minimax": { "base_url": "...anthropic/v1/messages", "model": "MiniMax-M3.1-Flash", "api_key": "sk-..." },
    "openai":  { "base_url": "https://api.openai.com/v1/chat/completions", "model": "gpt-4o-mini", "api_key": "sk-..." },
    "deepseek":{ "base_url": "https://api.deepseek.com/chat/completions", "model": "deepseek-chat", "api_key": "sk-..." }
  },
  "timeout": 12, "delay_ms": 900, "prompt": "..."
}
```

- 档位里的字段（`base_url` / `model` / `api_key` / `api` / `max_tokens` / `request_template` / `response_path` / `headers`…）**覆盖**顶层；
  其余（`prompt`、`delay_ms`、`skip_local`、`save`…）是全局的。
- 旧的单档写法（顶层直接写 `base_url`）仍然兼容。
- **在方案选单里选**（F4 / `Ctrl+Shift+E` / `` Ctrl+` ``）——`ai_profile` 是个收音机组，
  每个档位单独一行，✓ 表示当前档位：

```yaml
switches:
  - name: ai_profile
    options: [ ai_minimax, ai_openai ]      # 选项名，lua 用 ai_<档位名> 去读
    states: [ minimax, openai ]             # 选单里显示的文字
    reset: 0                                # 默认第 1 个
en_ai:
  profiles: "minimax,openai"                # 顺序必须和上面一致
```

选完立刻生效（lua 把选中的档位名写进 `ai_profile.txt`，桥下一次请求就用它），
日志里是 `已切换 AI：openai`，候选注释变成 `[AI]·openai`。没有快捷键。

### 配置项

| 字段 | 默认 | 作用 |
|---|---|---|
| `base_url` | — | 必填。完整 URL，如 `https://api.deepseek.com/chat/completions` |
| `api_key` | 空 | 走 `Authorization: Bearer <key>`；自定义鉴权用 `headers` |
| `model` | `gpt-4o-mini` | OpenAI 兼容接口的模型名 |
| `prompt` | 内置词典提示词 | system 消息 |
| `temperature` | 0 | 翻译要稳定，别发散 |
| `timeout` | 12 | 秒；超时只记日志，不影响打字 |
| `delay_ms` | 900 | 停手多久才请求（通常由 schema 的 `en_ai/delay_ms` 覆盖） |
| `min_input_len` | 2 | 太短不查 |
| `skip_local` | true | **本地词库有这个词就不花 API 钱** |
| `local_dict` | 自动找 `%APPDATA%\Rime\ecdict.dict.yaml` | 上面那条用的词表 |
| `request_template` | 空 | 非 OpenAI 形状的接口：`{"q":"{text}"}`，走这个模板 |
| `response_path` | `choices.0.message.content` | 从返回 JSON 里取译文（点号路径） |
| `headers` | 空 | 额外请求头，如 `{"X-Token": "..."}` |

OpenAI 兼容接口：

```json
{ "base_url": "https://api.deepseek.com/chat/completions",
  "model": "deepseek-chat", "api_key": "sk-...", "timeout": 12, "delay_ms": 900 }
```

自定义 HTTP 接口：

```json
{ "base_url": "https://my.api/translate",
  "request_template": "{\"q\": \"{text}\", \"src\": \"en\", \"dst\": \"zh\"}",
  "response_path": "data.translation",
  "headers": { "X-Token": "..." } }
```

### 发出去的是什么

只有**当前那个单词**，没有上下文、没有历史、没有你打的其它内容：

```json
{ "model": "deepseek-chat", "temperature": 0,
  "messages": [
    { "role": "system", "content": "你是英汉词典。把用户给出的英文单词或短语翻译成简体中文，只输出释义…" },
    { "role": "user",   "content": "hello" } ] }
```

### 省钱的四道闸

1. `skip_local`：本地 ECDICT 命中的词直接跳过（2 万高频词基本覆盖日常阅读）
2. `cache.json`：同一个词一辈子只查一次（存 `<tmp>/rime_en_ai/cache.json`，可删）
3. `delay_ms` 去抖：连续打字期间不发，只有停手才发
4. `Ctrl+Shift+A`：一键关掉整层 AI（或把 `ai_translate` 的 `reset` 改 0）

### 自检与排错

```powershell
python scripts\ai_bridge.py --once hello   # 不走 IME，直接验 key/网络/解析
python scripts\ai_bridge.py                # 常驻，日志里能看到 命中/缓存/跳过/译文
```

- 没有任何 `[AI]` 候选：先看桥有没有在跑；再看 `<tmp>\rime_en_ai\request.txt` 是否在变；再看 `%TEMP%\rime.weasel\*.WARNING.*` 有没有 `lua_gears.cc` 报错
- 桥日志显示 `x 本地已有释义，跳过 API`：这是预期行为，想强制查就设 `"skip_local": false`
- 注入 F24 失败（日志 `注入按键失败`）：结果仍会缓存，下一次按键时 `[AI]` 才出现

## 触发时机

- **停顿触发**：`en_ai/delay_ms`（在 `english.schema.yaml` 里，桥接进程按请求文件里的值走，改一处即可）。
- **显式触发**：`en_ai/trigger: "Control+Return"`，按下立刻请求（不用等停顿）。
- **关掉 AI**：`Ctrl+Shift+A`，或把 `ai_translate` 的 `reset` 改成 0。

`Ctrl+Shift+A` 用的是 rime 的 `toggle` 动作，定义在 `english.schema.yaml`：

```yaml
switches:
  - name: ai_translate
    reset: 1
    states: [ AI关, AI开 ]
key_binder:
  bindings:
    - { when: always, accept: "Control+Shift+A", toggle: ai_translate }
```

lua 两个脚本都会先看 `context:get_option("ai_translate")`：关掉后**不再写 `request.txt`、也不再出 `[AI]` 候选**，
本地词典完全不受影响。这个键只在英文模式里绑了，中文方案按它没反应。

## 为什么非要一个桥接进程

Rime 的 lua 没有定时器，也没有“空闲回调”；候选只在**按键时**生成。所以：

1. 「停手 N 毫秒」这件事只能由外部进程计时 → `ai_bridge.py`；
2. 结果回来时没人按键，候选不会自己刷新 → 桥注入一个 `F24` 假按键，`en_ai_request.lua` 收到后调
   `context:refresh_non_confirmed_composition()` 重绘。

同理，**候选生成路径上绝不能同步调网络**（`io.popen("curl …")` 会卡住打字），只写一个小文件是安全的。

## 三端注意

| 端 | 桥接注入 F24 | 备注 |
|---|---|---|
| Windows | `keybd_event(0x87)`，小狼毫实测可用 | 推荐 |
| macOS | `osascript` 模拟 F24，未必稳定 | 不稳定时把 `en_ai/trigger` 设一个键，手动触发 |
| Linux | 目前不注入 | AI 结果会在**下一次按键**时出现（缓存仍在） |

## 自测

```sh
lua test_en_ai.lua                 # 请求/响应文件协议 + 候选匹配 + 缓存
python3 scripts/ai_bridge.py --selftest   # 起本地假服务，验证 OpenAI 与自定义模板两条路
```
