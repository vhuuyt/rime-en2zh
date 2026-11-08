# rime-en2zh —— 英文输入 + 中文释义 + 大模型兜底翻译

给 [Rime](https://rime.im/) 的一套双语方案。**在中文输入里顺手查英文词**：

* **英文模式**：中文方案里单击 <kbd>Shift</kbd> → 切到英文模式，打字即出候选 —— 英文原词 + 中文释义（释义贴在候选右边，超宽自动滚动）。
* **本地词库**：ECDICT 4 万高频词 + 3 万时态变形 + 1.5 万化学词条（`titrate`/`esterify`…），`Hello` 这种首字母大写也查得到。离线可用、不花钱、**打字路径零文件 I/O**。
* **大模型兜底**：本地查不到的词，停手约 0.9 秒自动问一次 API（或按 <kbd>Tab</kbd> 立刻问），结果成为候选；
  按 Tab 查的词会写回 AI 词库，以后直接命中本地。
* **附带**：双拼 / 朙月拼音方案、Typst 片段词典、以词定字（写作向彩蛋，不影响主线）。

```
build/ 是部署产物，*.userdb/ 是学习记录 —— 都别手改
```

## 长什么样

英文模式下打 `info`：候选是单词，释义贴在后面。

* <kbd>空格</kbd> 上单词（自动补一个尾随空格，连打不粘词）
* <kbd>Ctrl+Enter</kbd> 上中文释义
* <kbd>Tab</kbd> 释义太长 → 滚动；本地没这个词 → 问 AI

![英文模式候选](docs/images/english-mode.png)

---

## 零、安装

### 1. 拉配置

```bash
git clone https://github.com/vhuuyt/rime-en2zh.git
cd rime-en2zh
```

### 2. 拷进 Rime 用户目录

Windows（PowerShell）：

```powershell
Copy-Item -Recurse -Force lua,scripts,dicts,docs,tests *.yaml "$env:APPDATA\Rime\"
```

macOS：一条命令（自动备份 + 保留机器专属文件 + 重新部署）

```bash
bash install-macos.sh
```

Linux：手动拷

```bash
# ibus
cp -r lua scripts dicts docs tests *.yaml ~/.config/ibus/rime/
# fcitx5
cp -r lua scripts dicts docs tests *.yaml ~/.local/share/fcitx5/rime/
```

### 3. 重新部署

托盘图标 → 重新部署（macOS 用 Squirrel 的「重新部署」）。部署后 `F4` 选单里就有「英文模式」。

英文词库**已随仓库提供**（`dicts/*.dict.yaml`，约 7MB），想换成自己生成的见[第三节](#三词库)。

### 4. 配大模型（可选）

不配也能用，只是生僻词没有释义。

```powershell
python scripts\ai_bridge.py --once hello     # 先验 key / 网络 / 解析
python scripts\install_autostart.py          # 装开机自启（--remove 卸载，--show 查看）
```

档位写在 `%APPDATA%\Rime\ai_config.json`（含 key，已 gitignore）—— 详见[第四节](#四接大模型)。

---

## 一、目录结构

```
%APPDATA%\Rime\
├── default.custom.yaml          方案列表（双拼 / 朙月 / 英文模式）、打开选单的热键
├── double_pinyin_mspy.custom.yaml   双拼：挂 lua 组件、标点、词库
├── luna_pinyin.custom.yaml          朙月拼音：同上
├── weasel.custom.yaml               Windows（Weasel）：皮肤 / 按应用 ascii_mode
├── squirrel.custom.yaml             macOS（Squirrel）：同上
├── english.schema.yaml              英文模式（独立方案，自带 lua 挂载）
├── ai_config.json               ★ 大模型配置（多档位都写这里，含 key，已 gitignore）
├── en.dict.yaml                 英文词库入口（只有 import_tables，正文在 dicts/）
├── vhuuyt.dict.yaml             中文词库入口（同上）
├── lua/                         输入法内部逻辑，全是 Lua（rime 自带解释器，无依赖）
│   ├── en_assoc.lua             英文：filter —— 释义贴到候选右边、跑马灯滚动、补单词候选
│   ├── en_ai_request.lua        英文：processor —— Tab / Ctrl+Enter / Ctrl+Delete / 档位同步
│   ├── en_space.lua             英文：processor —— 选词上屏时补尾随空格（连打不粘词）
│   ├── en_state.lua             英文：共享内存（滚动偏移、完整释义），避免按键读写文件
│   ├── mode_switch.lua          三方案：Shift 单击切方案（中文 ⇄ 英文模式）
│   ├── typst_shortcuts.lua      三方案：Ctrl+. / Ctrl+Shift+, / Ctrl+Shift+G
│   ├── typst_dict.lua           三方案：输入 typ 出片段候选
│   └── select_character.lua     双拼/朙月：以词定字 [ ]
├── scripts/                     需要计时器/网络/进程的部分（Python，只用标准库）
│   ├── ai_bridge.py             大模型桥（常驻）：轮询请求、调 API、写词库、热重载、自启
│   ├── ecdict2dict.py           ECDICT csv → 词库（含化学词库、时态变形）
│   ├── install_autostart.py     开机自启（Windows .vbs / macOS LaunchAgent / Linux .desktop）
│   └── lookup.py                命令行查词（看某个词在哪个库）
├── dicts/                       所有词库正文（根目录只留 Rime 要求的入口文件）
├── docs/
│   ├── ENGLISH-LOOKUP.md        英文模式细则（数据流、键位、AI 链路、排错）
│   └── MULTI-DEVICE.md          多端同步（Windows/macOS/Linux、Rime 同步 vs git）
└── tests/                       Lua 回归测试（不需要输入法就能跑）
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
| **空格 / 回车** | 上屏英文单词（**自动带一个尾随空格**；F4 里可关） |
| **`Ctrl+Enter`** | 上屏当前高亮候选的**中文释义** |
| **`Ctrl+Delete`** | 删掉这个 AI 补录的词（基库 ECDICT 的词不受影响），删完候选框收起。macOS 主键盘用 `Ctrl+BackSpace` |
| **`Tab`** | 三选一：释义超宽 → 往前滚 4 字；有短释义 → 放行给应用；**本地没这个词 → 立刻问一次 AI**（自动查是停手 0.9 秒后触发，不必按 Tab） |
| `F4` 选单 | **自动空格**开关（会记住）、AI 档位（✓ 当前）、AI 开关 |

### 通用

| 键 | 作用 |
|---|---|
| **左 `Shift`（单击）** | **中文 ⇄ 英文模式**：中文方案里单击切到「英文模式」，再单击切回刚才那个中文方案（**标点跟着切回中文**）。按住 Shift 打字不受影响（大写照常） |
| **右 `Shift`（单击）** | **中文 ⇄ 西文**（Rime 原生手感）：只切 `ascii_mode`，不换方案。想让它等同左 Shift：`english.schema.yaml` 里 `en_ai/shift_right: schema` |
| `F4` / `Ctrl+Shift+E` / `` Ctrl+` `` | 方案选单（切方案、切 AI 档位、AI 开关） |
| `Caps Lock` | 系统级大写（Shift 已被占用，大写在英文模式下用 Caps Lock） |

---

## 三、词库

| 文件 | 内容 | 能删吗 | 何时重建 |
|---|---|---|---|
| `dicts/ecdict.dict.yaml` | 7.4 万编码 / 14.8 万行（4 万词 + 3 万变形），5.7MB | 不能 | 想换规模/释义时重新生成 |
| `dicts/chem_ecdict.dict.yaml` | 1.5 万编码 / 3 万行，1.0MB | 不能 | 同上（一条命令一起生成） |
| `dicts/ai_ecdict.dict.yaml` | AI 查过且你按过 Tab 的词（**一律存小写**，打 `LaTeX`/`Latex`/`latex` 都能命中） | **能**（`Ctrl+Delete`） | 按 Tab 查词时桥自动写入（带 `#v` 版本号） |
| `dicts/sogouw` 等 | **中文词库**（双拼用）：搜狗、THUOCL、语料、符号、多音字 | 不能 | 换词库时替换文件 |

重新生成英文库（中文库不用动）：

```powershell
python scripts\ecdict2dict.py --csv C:\path\to\ecdict.csv `
    --out dicts\ecdict.dict.yaml --chem-out dicts\chem_ecdict.dict.yaml --limit 40000
```

`ecdict.csv` 来自 <https://github.com/skywind3000/ECDICT>（约 66MB）。生成完桥会自动重新部署。
没有 csv 时也能整理已有词库（每编码只留一条释义 + 加释义标记 + 剪掉大写变体，幂等）：

```powershell
python scripts\ecdict2dict.py --compact dicts\ecdict.dict.yaml dicts\chem_ecdict.dict.yaml
```

**词库格式**（一个编码下按权重降序；释义行的文本前有一个隐形标记 `\x01`，filter 靠它认行）：

```yaml
info            info    10    # <- 单词候选（权重 10）
\x01n. 信息；资料  info    0     # <- 释义行：搬成上面那条的 comment，自己消失
```

标记在显示前会被剥掉，你看不见；它的作用是让 filter **不用猜**"这行是词还是释义"
（否则释义本身是英文单词时就认错了）。

---

## 四、接大模型

### 1. 配置（只有这一个文件）

`%APPDATA%\Rime\ai_config.json`（旧位置 `%LOCALAPPDATA%\rime-en-ai\config.json` 会自动迁移）

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
  "skip_local": true,
  "save": true,
  "prompt": "你是英汉词典……只输出一行 JSON"
}
```

* `profiles` 的键名就是 F4 选单里的档位名；加一个档 → 桥自动写进选单并重新部署（**只维护这一个文件**）。
* 档位可覆盖：`base_url` `model` `api_key` `api` `max_tokens` `temperature` `request_template` `response_path` `headers` `anthropic_version`。
* 接口形状自动识别：URL 含 `anthropic` 或结尾 `/messages` → Anthropic 协议（`x-api-key` + `content[]`），否则 OpenAI 协议。
* 非标准接口用 `request_template`（`{text}` 占位）+ `response_path`（点号路径）。

### 2. 桥（常驻）

```powershell
python scripts\ai_bridge.py --once hello     # 先验 key/网络/解析
python scripts\ai_bridge.py                  # 前台跑（能看日志）
python scripts\install_autostart.py          # 装开机自启（--remove 卸载，--show 查看）
```

日志：`%TEMP%\rime_en_ai\bridge.log`（超过 1MB 自动轮转）。

桥除了查词，还兼职：

* 盯 `lua/*.lua` → 改了自动重启输入法（librime-lua 每个引擎会话只加载一次模块）
* 盯 `*.custom.yaml` / `*.schema.yaml` → 改了自动重新部署
* 盯 `ai_config.json` → 改了自动重读、必要时更新选单
* 盯 `scripts/ai_bridge.py` → **不**自动重载（它自己就在跑），只在日志里提醒你重启

---

## 五、日常操作

| 想做的事 | 怎么做 |
|---|---|
| 加 Typst 片段 | 改 `lua/typst_dict.lua` 里的 `builtin_entries`（key 只能用字母） |
| 删掉一个不想要的 AI 词 | 英文模式选中它 → `Ctrl+Delete`，或直接编辑 `dicts/ai_ecdict.dict.yaml`（别删 `#v` 行） |
| 查某个词在不在库里 | `python scripts\lookup.py typst titration ran` |
| 加一个 AI 档位 | 只改 `ai_config.json` 的 `profiles` |
| 改完配置要手动部署吗 | 不用，桥 3 秒内自己动手；只有桥没跑时才需要托盘「重新部署」 |

---

## 六、排错

| 现象 | 先看哪里 |
|---|---|
| 不按 Tab 也不出 AI 释义 | 桥有没有跑（`bridge.log`）；档位有没有填 `base_url`；词太短（`min_input_len` 默认 2）；`en_ai/auto` 是不是 0 |
| 出了 AI 释义但候选栏没刷新 | 桥返回后会注入一次 F24 触发重绘；如果某个应用吃掉 F24，下一键就会刷出来 |
| 改了 `scripts/ai_bridge.py` 没生效 | 桥是常驻进程，**要重启**（`bridge.log` 里会提醒）；改 `lua/*.lua` 才是自动生效 |
| 本地词也不出释义 | 是否已在「英文模式」（不是 `ascii_mode` 直通）；`build/en.table.bin` 是否比源文件新 |
| 改了 lua 没生效 | 桥会自动重启输入法；没跑桥就手动重启小狼毫（改 lua 光部署无效） |
| 部署失败 / 反复部署 | `%TEMP%\rime.weasel\*.log`；用户目录里有没有名叫 `nul` 的文件（会让部署崩） |
| 想强制全量重建 | 删 `build/` 后重新部署，或重新生成词库 |

---

## 七、测试

```bash
bash tests/run.sh                # 组件级：7 个 Lua 测试（Windows 可在 WSL / Git Bash 里跑）
bash tests/run.sh en_assoc       # 只跑一个
python scripts/ai_bridge.py --selftest   # 桥：API 协议 / 词库读写
python scripts/probe.py --check          # 端到端：真的敲键，看候选和上屏
```

`tests/*.lua` 会自己找上一级的 `lua/`，放哪儿都能跑；只依赖标准 Lua（用到 `utf8`）。

`scripts/probe.py` 用 librime 自己的 C API 模拟按键（不弹窗、不抢焦点、只读），所以能验证
"词库 → 候选 → 上屏"这条真链路，而不只是组件行为：

```bash
python scripts/probe.py Hello LaTeX        # 打这些词，列出候选和释义
python scripts/probe.py --pages 0 typ      # 翻到底（默认只第一页，每页 9 条）
python scripts/probe.py --commit Hello     # 看上屏文本（自动补一个空格）
python scripts/probe.py --check            # 改完词库/lua 跑这个，10 条断言
```

---

## 八、设计说明

**为什么英文模式打字不卡**：键和候选之间的路径上没有任何文件读写 —— 滚动偏移和完整释义放在 `lua/en_state.lua` 的共享内存里；释义不需要"查表"，因为它本来就在候选流里（见第三节的词库格式），filter 只做搬运。零文件 I/O 的代价是首次进入不再解析整本词表（之前那一步要 0.3–0.6 秒）。

**为什么 AI 要按 Tab 才触发**：早期是"停手 900ms 自动查"，那要求每次按键都写一次请求文件（同步 I/O，~0.3ms/键，还会被磁盘/杀毒拖慢）。现在打字完全不碰磁盘，只有 Tab 这一下写一次。

**大小写**：Rime 的码表查询是精确匹配（`prism->GetValue`），词库里只有 `hello` 时打 `Hello` 一条候选都没有。
解法不是复制词条，而是在 `english.schema.yaml` 里用拼写运算派生：

```yaml
speller:
  algebra:
    - derive/^(.)(.*)$/\u$1$2/     # hello → Hello，指向同一条词条
```

编译建 prism 时对每个码派生一个首字母大写码（`dict_compiler.cc` 读 schema 的 `speller/algebra`），
所以**词库里一份小写就够**，`en.table.bin` 不会因为大写而翻倍。代价：全大写（`HELLO`）不可查；
候选正文是小写，上屏时由 `lua/en_space.lua` 按你敲的输入补回大写。

**更多细节**：`docs/ENGLISH-LOOKUP.md`（数据流、键位、AI 链路、排错）、`docs/MULTI-DEVICE.md`（配置走 git，`*.userdb` 走 Rime 同步，`build/` 和 `ai_config.json` 不进仓库）。
