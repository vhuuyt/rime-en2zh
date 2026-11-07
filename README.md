# Rime 配置说明（这套配置是干什么的）

一整套给 Typst 写作者用的 Rime 方案：

* **双拼 / 朙月拼音**：中文输入 + `typ` 片段词典 + 以词定字
* **英文模式**：英文查词（本地 7 万词）+ 带释义的候选 + 可选的大模型翻译

```
双击哪个都别删：build/ 是部署产物，*.userdb/ 是学习记录
```

---

## 一、目录结构

```
%APPDATA%\Rime\
├── default.custom.yaml          方案列表（双拼 / 朙月 / 英文模式）、打开选单的热键
├── double_pinyin_mspy.custom.yaml   双拼：挂 lua 组件、标点、词库
├── luna_pinyin.custom.yaml          朙月拼音：同上
├── english.schema.yaml              英文模式（独立方案，自带 lua 挂载）
├── ai_config.json               ★ 大模型配置（多个 AI 档位都写这里，含 key，已 gitignore）
├── ecdict.dict.yaml             ★ 基础词库：4 万高频词 + 3 万时态变形
├── chem_ecdict.dict.yaml        ★ 基础词库：1.6 万化学词（由 ecdict 的 import_tables 合并）
├── ai_ecdict.dict.yaml          ★ AI 补录词库（唯一可删的，Ctrl+Delete 只动它）
├── lua/                         输入法内部逻辑，全是 Lua（rime 自带，无依赖）
│   ├── typst_shortcuts.lua      三方案：Ctrl+. / Ctrl+Shift+, / Ctrl+Shift+G
│   ├── typst_dict.lua           三方案：输入 typ 出片段候选
│   ├── select_character.lua     双拼/朙月：以词定字 [ ]
│   ├── en_ai_request.lua        英文：按键处理（Tab / Ctrl+Enter / Ctrl+Delete / 档位同步）
│   ├── en_ai_candidate.lua      英文：把桥查到的译文变成候选
│   └── en_assoc.lua             英文：候选改造（释义贴尾部、滚动、补单词候选）
├── scripts/                     需要计时器/网络/进程的部分（Python，标准库）
│   ├── ai_bridge.py             大模型桥（常驻）：计时、调 API、写词库、热重载
│   ├── ecdict2dict.py           ECDICT csv → 词库（含化学词库、时态变形）
│   ├── install_autostart.py     开机自启（Windows .vbs / macOS LaunchAgent / Linux .desktop）
│   └── lookup.py                命令行查词（看某个词在哪个库）
├── docs/
│   ├── ENGLISH-LOOKUP.md        英文模式细则（候选、键位、AI 链路）
│   └── MULTI-DEVICE.md          多端同步（Windows/macOS/Linux、Rime 同步 vs git）
└── tests/                       五个 Lua 回归测试（不需要输入法就能跑）
```

运行时目录（不在这里，别手改）：`%TEMP%\rime_en_ai\`（请求文件、缓存、日志）

---

## 二、快捷键

### 中文（双拼 / 朙月）

| 键 | 作用 |
|---|---|
| `[` / `]` | 以词定字：取当前候选的首字 / 末字 |
| `Ctrl+.` | 插入 `#super[` |
| `Ctrl+Shift+,` | 插入 `#sub[` |
| `Ctrl+Shift+G` | 插入 `#figure(image(""), caption: [])` |
| `typ` + 前缀 | Typst 片段候选（`typfig`、`typs`…） |

### 英文模式

| 键 | 作用 |
|---|---|
| 打字 | 候选：单词（带释义）+ 前缀联想的其它单词 |
| **空格 / 回车** | 上屏英文单词 |
| **`Ctrl+Enter`** | 上屏当前高亮候选的**释义**（中文） |
| **`Ctrl+Delete`** | 删掉这个 AI 补录的词（基库词不受影响），删完候选框收起 |
| **`Tab`** | 释义超过窗口宽度时往前滚（每次 4 字，可调） |
| `Ctrl+Shift+A` | AI 总开关 |

### 通用

| 键 | 作用 |
|---|---|
| `F4` / `Ctrl+Shift+E` / `` Ctrl+` `` | 方案选单（切换方案、切 AI 档位、AI 开关） |

---

## 三、词库：三层 + 中文库

| 文件 | 内容 | 能删吗 | 何时重建 |
|---|---|---|---|
| `ecdict.dict.yaml` | 4 万高频词 + 3 万变形（`ran`/`bigger`/`titrated`） | 不能 | 改 `--limit` 重新生成 |
| `chem_ecdict.dict.yaml` | 1.6 万 `[化]` 词条 + 实验常用词（`titrate`/`esterify`/`spectrophotometry`） | 不能 | 同上（一条命令一起生成） |
| `vhuuyt.dict.yaml` + `dicts/` | **中文词库**（双拼用）：搜狗词库、THUOCL、语料词表、符号、多音字 | 不能 | 换词库时手工替换 `dicts/` |
| `ai_ecdict.dict.yaml` | AI 查过的词，含大写版本 | **能**（`Ctrl+Delete`） | 桥自动写入 |

重新生成前两个英文库（中文库不用重新生成）：

```powershell
python scripts\ecdict2dict.py --csv C:\path\to\ecdict.csv `
    --out ecdict.dict.yaml --chem-out chem_ecdict.dict.yaml --limit 40000
```

（`ecdict.csv` 来自 <https://github.com/skywind3000/ECDICT>，约 66MB。桥看到 `*.dict.yaml` 变了会自动重新部署。）

---

## 四、接大模型

### 1. 配置（只有这一个文件）

`%APPDATA%\Rime\ai_config.json`（旧位置 `%LOCALAPPDATA%\rime-en-ai\config.json` 会被自动迁移过来）

```json
{
  "active": "minimax",
  "profiles": {
    "minimax":  { "base_url": "https://api.minimax.cn/anthropic/v1/messages",
                  "model": "MiniMax-M3.1-Flash", "api_key": "sk-..." },
    "openai":   { "base_url": "https://api.openai.com/v1/chat/completions",
                  "model": "gpt-4o-mini", "api_key": "sk-..." }
  },
  "timeout": 12,
  "delay_ms": 900,
  "skip_local": true,
  "save": true,
  "prompt": "你是英汉词典……只输出一行 JSON"
}
```

* `profiles` 的键名就是方案选单里的档位名；加一个档 → 桥会自动把它写进选单并重新部署（**只维护这一个文件**）。
* 档位里可覆盖的字段：`base_url` `model` `api_key` `api` `max_tokens` `temperature`
  `request_template` `response_path` `headers` `anthropic_version`；其余是全局。
* 接口形状自动识别：URL 含 `anthropic` 或结尾 `/messages` → Anthropic 协议（`x-api-key` + `content[]`），
  否则 OpenAI 协议（`Authorization` + `choices[0].message.content`）。
* 非标准接口用 `request_template`（`{text}` 占位）+ `response_path`（点号路径）。

切档：`F4` 选单里的 `minimax / openai …`（✓ 是当前档），候选注释会显示 `[AI]·openai`。

### 2. 桥（常驻）

```powershell
python scripts\ai_bridge.py --once hello     # 先验 key/网络/解析
python scripts\ai_bridge.py                  # 前台跑（能看日志）
python scripts\install_autostart.py          # 装开机自启（--remove 卸载，--show 查看）
```

日志：`%TEMP%\rime_en_ai\bridge.log`（超过 1MB 自动轮转）。

桥除了查词，还兼职：

* 盯着 `lua/*.lua` → 改了自动重启输入法（librime-lua 每个会话只加载一次模块）
* 盯着 `*.custom.yaml` / `*.schema.yaml` / `*.dict.yaml` → 改了自动重新部署
* 盯着 `ai_config.json` → 改了自动重读、必要时更新选单

---

## 五、日常操作

| 想做的事 | 怎么做 |
|---|---|
| 加 Typst 片段 | 改 `lua/typst_dict.lua` 里的 `builtin_entries`（key 只能用字母） |
| 给 AI 补过的词加中文释义进词库 | 已经自动写进 `ai_ecdict.dict.yaml`，不用管 |
| 删掉一个不想要的 AI 词 | 英文模式选中它 → `Ctrl+Delete`，或直接编辑 `ai_ecdict.dict.yaml`（别删 `#v` 行） |
| 查某个词在不在库里 | `python scripts\lookup.py typst titration ran` |
| 加一个 AI | 只改 `ai_config.json` 的 `profiles` |
| 改完配置要手动部署吗 | 不用，桥 3 秒内自己动手；只有桥没跑时才需要托盘「重新部署」 |

---

## 六、排错

| 现象 | 先看哪里 |
|---|---|
| 没有 `[AI]` 候选 | 桥有没有跑（`bridge.log`）；档位是否没填 `base_url`（日志会写"跳过请求"） |
| 词库里的词也不出释义 | 输入法是否已是「英文模式」；`build/ecdict.table.bin` 是否比源文件新 |
| 改了 lua 没生效 | 桥会自动重启输入法；没跑桥就手动重启小狼毫 |
| 部署失败/反复部署 | `%TEMP%\rime.weasel\*.log`；用户目录里有没有名叫 `nul` 的文件（会让部署崩） |
| 想强制全量重建 | `python scripts\ecdict2dict.py ...` 重新生成词库，或删 `build/` 后部署 |

---

## 七、测试

```powershell
cd $env:APPDATA\Rime
for ($f in (Get-ChildItem tests\*.lua)) { lua $f.FullName }
python scripts\ai_bridge.py --selftest
```

`tests/` 里的脚本会自己找上一级的 `lua/`，放在哪儿都能跑。

都只依赖标准 Lua（用到 `utf8`）和 Python 标准库，不需要输入法在跑。

---

## 八、多端

`docs/ENGLISH-LOOKUP.md` 写英文模式细节，`docs/MULTI-DEVICE.md` 写 Windows/macOS/Linux 三端怎么共享配置
（结论：配置走 git，`*.userdb` 走 Rime 自带的同步，`build/` 和 `ai_config.json` 不进仓库）

`dicts/` 不是"下载了没用"的东西：`vhuuyt.dict.yaml` 的 `import_tables` 把它们全合并进来，
双拼方案的 `translator/dictionary: vhuuyt` 就是用这一套。**删了中文就没词了。**。
