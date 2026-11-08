# 多端 Rime 配置（Windows Weasel / macOS Squirrel / Linux ibus-rime）

## 1. 先认清三端的按键差异（这就是 `Ctrl+Shift+,` 在 Windows 上失效的原因）

`key:repr()` 是「修饰键 + X11 keysym 名」。修饰键顺序三端一致，但**键名来源三家不同**：

| 端 | 键名来源 | `Ctrl+Shift+,` 的 repr | `Ctrl+Shift+G` 的 repr |
|---|---|---|---|
| Windows（Weasel） | `ToUnicodeEx()`，只清 Ctrl/Alt，**保留 Shift** → 取到 `'<'` | `Shift+Control+less` | `Shift+Control+G` |
| macOS（Squirrel） | `kVK_ANSI_Comma → XK_comma` 物理键位表优先 | `Shift+Control+comma` | `Shift+Control+G` |
| Linux（ibus-rime） | X11 keysym（移位后是 `less`） | `Shift+Control+less` | `Shift+Control+G` |

结论：
* 标点类组合键在表里**两个名字都写**，三端才能一致（`lua/typst_shortcuts.lua` 已这么做）。
* 字母键三端一致，但 Shift 按下时是**大写**：`Control+f` vs `Shift+Control+G`。

## 2. 文件分三类

| 分类 | 文件 | 怎么同步 |
|---|---|---|
| **配置源码（三端共享）** | `default.custom.yaml`、`double_pinyin_mspy.schema.yaml`、`double_pinyin_mspy.custom.yaml`、`lua/*.lua`、`*.dict.yaml`、`dicts/` | git 仓库（或任意文件同步工具） |
| **平台专属** | `weasel.custom.yaml`（exe 名作 key）、`squirrel.custom.yaml`（bundle id 作 key、皮肤） | 跟配置一起同步，但只有对应前端会读，互不干扰 |
| **机器专属 / 产物** | `build/`、`*.userdb/`、`installation.yaml`、`user.yaml`、`trash/` | 不要同步（见 `.gitignore`） |

## 3. Rime 自带的「同步」到底干了什么（实测自你的 sync 目录）

你的 `installation.yaml`：`sync_dir: C:\Users\peter\iCloudDrive\Rime\`，`installation_id: Rime-Win-AMD`。
实际产物：

```
iCloudDrive/Rime/
├── Rime-Win-AMD/     ← Windows 这台
├── Rime_Squirrel/    ← macOS
└── ibus-rime/        ← Linux
```

每端写进**自己**的子目录，所以不会互相覆盖。看 librime 的 `BackupConfigFiles` 实现，它：

* 只备份用户目录**顶层**的 `*.yaml` 和 `*.txt`；
* `IsCustomizedCopy()` 会跳过带 `customization:` 头的非 `.custom.yaml`（如自动生成的 `weasel.yaml`）；
* 只有上传，**没有回铺任务**（librime 里没有 restore 之类），所以另一端不会自动拿到你的改动；
* **`lua/` 子目录完全不在备份范围内** —— 这就是「配置同步了但快捷键没跟着走」的根因。

所以分工只能是：

* **Rime 同步** → `*.userdb`（学习记录合并，`UserDictManager::SynchronizeAll`）
* **git / 网盘** → 方案、补丁、`lua/`、词库源码

## 4. 落地步骤

### Windows（当前这台）

```powershell
cd $env:APPDATA\Rime
git init
git add -A
git commit -m "rime config: lua snippets + 以词定字"
git remote add origin <你的私有仓库>
git push -u origin main
```

### macOS

```sh
cd ~/Library/Rime
git clone <你的私有仓库> .        # 或 clone 到别处再 rsync，避开安装器生成的默认文件
# 三端一致的文件：double_pinyin_mspy.*、lua/、default.custom.yaml、vhuuyt.dict.yaml
# 保留本机自己的：squirrel.custom.yaml、installation.yaml、user.yaml、build/
```

mac 端注意：

1. `squirrel.custom.yaml` 别覆盖——里面是 bundle id 的 `app_options` 和 `mac_light` 皮肤。
2. 你之前在 `~/Library/Rime/double_pinyin_mspy.custom.yaml` 里试过
   `ascii_composer/switch_key/Shift_L: noop`：这类「三端都要」的补丁可以留在共享文件里，
   「只在本端」的就挪到 `squirrel.custom.yaml` / `weasel.custom.yaml`。
3. mac 的 rep 里 `Ctrl+Shift+,` 是 `Shift+Control+comma`，已经在脚本表里，无需改动。

### 部署 / 重载

```powershell
& "C:\Program Files\Rime\weasel-0.17.4\WeaselDeployer.exe" /deploy
```

```sh
"/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel" --reload
```

## 5. 不要做的事

* **不要把整个用户目录丢进 iCloud/OneDrive 当同步盘**：`build/` 有 60MB+ 二进制，`*.userdb`
  是 LevelDB（运行中被云端抓取会损坏/产生冲突副本），而且 `installation.yaml` 的 `sync_dir`
  两端路径不同，互相覆盖后同步就哑了。
* 不要同步 `build/`：`*.table.bin`、`*.prism.bin` 与 rime 版本、平台相关，换端必然重建。
* `default.custom.yaml` 顶部的 `customization:` 头会被各端设置界面重写（版本号不同 → 天天冲突）。
  想干净就只留 `patch:` 段。

## 6. 自测

```sh
lua test_typst_shortcuts.lua   # Ctrl+. / Ctrl+Shift+, / Ctrl+Shift+F
lua test_typst_dict.lua        # typ → 片段候选
lua test_select_character.lua  # 以词定字
```

三个脚本只依赖标准 Lua（5.1+，用到 `utf8`），不依赖小狼毫进程。

## 7. iCloud 同步目录实况（`sync_dir` 里都是什么）

`sync_dir` 设的是 `iCloudDrive/Rime/`，里面按 `installation_id` 分目录，**每端各写自己那份**：

| 目录 | 来源 | 里面有什么 | 状态 |
|---|---|---|---|
| `Rime_Squirrel/` | macOS | 顶层 `*.yaml` + `*.txt`（`squirrel.custom.yaml` 只在这里有） | 活的（会随 Mac 部署刷新） |
| `Rime-Win-AMD/` | 这台 Windows | 同上 + 旧的 `ecdict/chem_ecdict/ai_ecdict.dict.yaml`（已挪进 `dicts/`） | 停在 2026-11-07，早于 Shift 切换和词库重构 |
| `Rime-Win/` | 早期 Windows | `distribution_version: 0.14.3`、`rime_version: 1.5.3` | 2026-05 的化石，忽略 |
| `ibus-rime/` | 早期 Linux | 还带着 `easy_en.*`、`ibus_rime.custom.yaml` | 2026-06 的化石，忽略 |

关键点（librime 的 `BackupConfigFiles` 实现）：

* **只备份用户目录顶层的 `*.yaml` 和 `*.txt`** —— `lua/`、`scripts/`、`dicts/`、`docs/` 都不在里面，
  所以「配置同步了、但 lua 没跟着走」是必然的，别指望 sync_dir 当代码同步。
* **只有上传，没有回铺**：A 端的改动不会自动长到 B 端。
* 所以 `sync_dir` 只能当**快照 / 备份**看，源码仍以 git 仓库为准。

判断某端是不是最新，看它 `english.schema.yaml` 里这一行在不在 `processors`（而不是 `filters`）：

```yaml
    - lua_processor@*en_space           # 选词上屏时自动补尾随空格
```

在 `filters` 里就是旧的坏版本（filter 改 `cand.text` 对 `Phrase` 候选无效，见 `ENGLISH-LOOKUP.md`）。
