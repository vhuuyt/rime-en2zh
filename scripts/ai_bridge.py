#!/usr/bin/env python3
"""Rime 英文查词 · 大模型翻译桥接

为什么需要这个进程：Rime/lua 没有定时器，做不到「停手 N 毫秒后触发」。
本进程只做三件事，纯标准库，不装依赖：

  1. 盯着 <tmp>/rime_en_ai/request.txt（lua 每次按键写一次）
  2. 文件内容稳定 delay_ms 毫秒后，调用你配置的 API
  3. 写 response.txt，再注入一个 F24 假按键让 Rime 重绘候选

配置文件（默认不在 Rime 目录里，避免 API key 进 git）：
    Windows : %LOCALAPPDATA%\\rime-en-ai\\config.json
    macOS   : ~/.config/rime-en-ai/config.json
    Linux   : ~/.config/rime-en-ai/config.json

config.json 示例（OpenAI 兼容接口）：
{
  "base_url": "https://api.openai.com/v1/chat/completions",
  "model":    "gpt-4o-mini",
  "api_key":  "sk-...",
  "timeout":  12,
  "delay_ms": 900,
  "prompt":   "你是英汉词典。把用户给出的英文单词或短语翻译成简体中文，只输出释义（多个义项用「；」分隔），不要拼音、不要例句、不要解释。"
}

任意自定义 HTTP 接口：给出 request_template（占位符 {text}）与 response_path（点号路径）：
{
  "base_url": "https://my.api/translate",
  "request_template": "{\"q\": \"{text}\", \"src\": \"en\", \"dst\": \"zh\"}",
  "response_path": "data.translation",
  "headers": {"X-Token": "..."}
}

用法:
    python scripts/ai_bridge.py                 # 常驻
    python scripts/ai_bridge.py --once hello     # 查一个词看看通不通
    python scripts/ai_bridge.py --selftest       # 离线自测（起本地假服务）
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

POLL_SEC = 0.05
VK_F24 = 0x87
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
DETACHED_PROCESS = 0x00000008 if os.name == "nt" else 0

DEFAULT_PROMPT = (
    "你是英汉词典，负责给 Rime 输入法词库填字段（候选栏空间很小）。"
    "用户给出一个英文单词，只输出一行严格 JSON（不要代码块、不要解释）：\n"
    '{"zh": "简体中文释义，最多 12 个汉字，最多 2 个义项，用；分隔，'
    '不要拼音、不要例句、不要解释性文字", '
    '"pos": "词性缩写 n./v./adj./adv./prep./pron./conj./int./num.，不确定就空串", '
    '"cap": true/false}\n'
    "cap 表示该词是否通常首字母大写（人名、地名、品牌、产品名为 true）。"
)


# ---------------------------------------------------------------- 路径与配置
def bridge_dir(cfg):
    d = cfg.get("dir") or os.path.join(tempfile.gettempdir(), "rime_en_ai")
    return d


def config_paths():
    """配置查找顺序：Rime 用户目录（推荐）→ 旧位置 → scripts/config.json。

    放在 Rime 用户目录里，和 schema/lua 待在一起，备份/迁移时一并带走；
    .gitignore 已经排除了它（里面是 API key）。
    """
    _, user_dir = rime_paths({})
    paths = [os.path.join(user_dir, "ai_config.json")]
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        paths.append(os.path.join(base, "rime-en-ai", "config.json"))
    else:
        paths.append(os.path.expanduser("~/.config/rime-en-ai/config.json"))
    paths.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json"))
    return paths


PROFILE_KEYS = ("base_url", "model", "api_key", "api", "max_tokens", "temperature",
                "anthropic_version", "request_template", "response_path", "headers")


SWITCH_BEGIN = "# >>> ai_profile auto"
SWITCH_END = "# <<< ai_profile auto"
NAMES_BEGIN = "# >>> ai_names auto"
NAMES_END = "# <<< ai_names auto"


def sync_schema(cfg):
    """把 config.json 里的档位名写进 schema 的选单（这样只维护一个配置文件）。

    改写两处带标记的区块：
      switches: ai_profile 的 options / states
      en_ai: profiles 那一行
    """
    _, user_dir = rime_paths(cfg)
    profiles = list((cfg.get("profiles") or {}).keys())
    if not profiles:
        return False
    schema = os.path.join(user_dir, "english.schema.yaml")
    try:
        with open(schema, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError:
        return False

    opts = ", ".join('"ai_%s"' % p for p in profiles)
    # 选单里显示成 "AI: minimax"，这样一眼看出这是一组互斥的档位（选中的带 ✓）
    states = ", ".join('"AI: %s"' % p for p in profiles)
    switch_block = [
        "  " + SWITCH_BEGIN,
        "  - name: ai_profile",
        f"    options: [ {opts} ]",
        f"    states: [ {states} ]",
        "    reset: 0",
        "  " + SWITCH_END,
    ]
    names_block = [
        "  " + NAMES_BEGIN,
        '  profiles: "%s"' % ",".join(profiles),
        "  " + NAMES_END,
    ]

    def replace(lines, begin, end, block):
        try:
            i = next(k for k, l in enumerate(lines) if begin in l)
            j = next(k for k, l in enumerate(lines) if end in l)
        except StopIteration:
            return lines, False
        return lines[:i] + block + lines[j + 1:], True

    changed = False
    lines, ok1 = replace(lines, SWITCH_BEGIN, SWITCH_END, switch_block)
    lines, ok2 = replace(lines, NAMES_BEGIN, NAMES_END, names_block)
    if not (ok1 and ok2):
        return False
    text = "\n".join(lines)
    try:
        with open(schema, encoding="utf-8") as f:
            old = f.read()
    except OSError:
        old = ""
    if text == old:
        return False
    with open(schema, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    log("已把档位写进方案选单: " + ", ".join(profiles))
    changed = True
    return changed


def needs_deploy(cfg):
    """源码 schema 比 build 里的新 → 需要部署。"""
    _, user_dir = rime_paths(cfg)
    src = os.path.join(user_dir, "english.schema.yaml")
    bld = os.path.join(user_dir, "build", "english.schema.yaml")
    try:
        return os.path.getmtime(src) > os.path.getmtime(bld)
    except OSError:
        return False


def active_profile(cfg):
    """把 profiles + active 合并成一份可用配置（兼容旧的单档写法）。"""
    merged = dict(cfg)
    profiles = cfg.get("profiles") or {}
    name = cfg.get("active") or (next(iter(profiles), None))
    if profiles:
        prof = profiles.get(name) or next(iter(profiles.values()))
        merged.update(prof or {})
        merged["_profile"] = name if name in profiles else next(iter(profiles))
    else:
        merged["_profile"] = "default"
    return merged


def migrate_config():
    """把旧位置的配置搬到 Rime 用户目录里（只做一次）。"""
    new_path = config_paths()[0]
    if os.path.isfile(new_path):
        return None
    for old in config_paths()[1:]:
        if os.path.isfile(old):
            try:
                os.makedirs(os.path.dirname(new_path), exist_ok=True)
                with open(old, encoding="utf-8") as f:
                    data = f.read()
                with open(new_path, "w", encoding="utf-8") as f:
                    f.write(data)
                return f"{old} → {new_path}"
            except OSError:
                return None
    return None


def load_config(path=None):
    if path:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
        cfg["_source"] = path
        return cfg
    for p in config_paths():
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                cfg = json.load(f)
            cfg["_source"] = p
            return cfg
    return {"_source": None}


# ---------------------------------------------------------------- 请求
def parse_result(text):
    """模型输出 → {"zh","pos","cap"}；不是 JSON 就整段当释义（兼容旧 prompt）。"""
    raw = (text or "").strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:]
        raw = raw.strip()
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            zh = str(obj.get("zh") or obj.get("translation") or "").strip()
            if zh:
                pos = str(obj.get("pos") or "").strip()
                cap = obj.get("cap")
                return {"zh": zh, "pos": pos, "cap": bool(cap)}
    except (json.JSONDecodeError, ValueError):
        pass
    return {"zh": raw, "pos": "", "cap": False}


def normalize_entry(v):
    """把缓存里的旧格式（纯字符串）或残缺 dict 统一成 {"zh","pos","cap"}。"""
    if isinstance(v, str):
        return {"zh": v, "pos": "", "cap": False}
    if isinstance(v, dict) and isinstance(v.get("zh"), str) and v["zh"]:
        return {"zh": v["zh"], "pos": str(v.get("pos") or ""), "cap": bool(v.get("cap"))}
    return None


MAX_ZH = 20          # 释义总长上限（候选栏放得下）


def short_zh(zh):
    """把 AI 返回的释义裁到能塞进候选栏的长度。"""
    zh = " ".join((zh or "").split())
    if len(zh) <= MAX_ZH:
        return zh
    cut = zh[:MAX_ZH]
    for sep in ("；", ";", "，", ","):
        i = cut.rfind(sep)
        if i >= 6:
            return cut[:i]
    return cut.rstrip("，,；; ") + "…"


def display_text(entry):
    """候选里显示的文本：'n. 电脑, 计算机'"""
    zh, pos = entry.get("zh", ""), entry.get("pos", "")
    return f"{pos} {zh}".strip() if pos else zh


def api_kind(cfg):
    kind = (cfg.get("api") or "auto").lower()
    if kind != "auto":
        return kind
    url = (cfg.get("base_url") or "").lower()
    if "anthropic" in url or url.rstrip("/").endswith("/messages"):
        return "anthropic"
    return "openai"


def build_payload(cfg, word, kind="openai"):
    if kind == "anthropic":
        return {
            "model": cfg.get("model", ""),
            "max_tokens": int(cfg.get("max_tokens", 400)),
            "temperature": cfg.get("temperature", 0),
            "system": cfg.get("prompt", DEFAULT_PROMPT),
            "messages": [{"role": "user", "content": word}],
        }
    return build_openai_payload(cfg, word)


def build_openai_payload(cfg, word):
    tpl = cfg.get("request_template")
    if tpl:
        return json.loads(tpl.replace("{text}", word))
    return {
        "model": cfg.get("model", "gpt-4o-mini"),
        "temperature": cfg.get("temperature", 0),
        "messages": [
            {"role": "system", "content": cfg.get("prompt", DEFAULT_PROMPT)},
            {"role": "user", "content": word},
        ],
    }


def dig(obj, path):
    cur = obj
    for part in path.split("."):
        if isinstance(cur, list):
            cur = cur[int(part)]
        elif isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
        if cur is None:
            return None
    return cur


def translate(cfg, word, retried=False):
    """返回 {"zh","pos","cap"}；失败返回 None。"""
    url = cfg.get("base_url")
    if not url:
        log("config.json 里还没有填 base_url，跳过请求")
        return None
    kind = api_kind(cfg)
    headers = {"Content-Type": "application/json"}
    if kind == "anthropic":
        if cfg.get("api_key"):
            headers["x-api-key"] = cfg["api_key"]
        headers.setdefault("anthropic-version", cfg.get("anthropic_version", "2023-06-01"))
    elif cfg.get("api_key"):
        headers["Authorization"] = "Bearer " + cfg["api_key"]
    headers.update(cfg.get("headers") or {})

    payload = build_payload(cfg, word, kind)
    extra = cfg.get("extra_body")          # 例如 {"thinking": {"type": "disabled"}}
    if isinstance(extra, dict):
        payload.update(extra)
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=cfg.get("timeout", 12)) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
        log(f"请求失败: {e}")
        return None

    text = None
    path = cfg.get("response_path")
    if path:
        text = dig(body, path)
    if not isinstance(text, str):
        text = extract_text(body)
    if not isinstance(text, str):
        reason = body.get("stop_reason") if isinstance(body, dict) else None
        blocks = body.get("content") if isinstance(body, dict) else None
        kinds = [b.get("type") for b in blocks if isinstance(b, dict)] if isinstance(blocks, list) else None
        log(f"没拿到译文：stop_reason={reason} blocks={kinds}")
        if reason == "max_tokens" and not retried:
            # 思维链把 token 吃光了：再问一次，明确要求直接给 JSON，预算翻倍
            log("重试一次（要求直接输出 JSON）")
            return translate(cfg, word + "  -- 直接输出 JSON，不要任何思考过程、不要解释", retried=True)
        return None
    text = " ".join(text.split()).strip()
    if not text:
        return None
    return parse_result(text)


def extract_text(body):
    """OpenAI / Anthropic / MiniMax 三种常见形状都能取到正文（跳过 thinking 块）。"""
    if not isinstance(body, dict):
        return None
    # OpenAI: choices[0].message.content
    ch = body.get("choices")
    if isinstance(ch, list) and ch:
        msg = ch[0].get("message") if isinstance(ch[0], dict) else None
        if isinstance(msg, dict) and isinstance(msg.get("content"), str):
            return msg["content"]
    # Anthropic / MiniMax: content = [{type: thinking|text, text: ...}]
    blocks = body.get("content")
    if isinstance(blocks, list):
        for b in blocks:
            if isinstance(b, dict) and b.get("type", "text") == "text" and isinstance(b.get("text"), str):
                return b["text"]
    for key in ("output_text", "text", "translation", "result"):
        if isinstance(body.get(key), str):
            return body[key]
    return None


# ---------------------------------------------------------------- 注入按键
def inject_refresh():
    """让 Rime 重绘候选（F24 在应用里基本无副作用）。"""
    try:
        if os.name == "nt":
            import ctypes
            user32 = ctypes.windll.user32
            user32.keybd_event(VK_F24, 0, 0, 0)
            user32.keybd_event(VK_F24, 0, 0x0002, 0)   # KEYEVENTF_KEYUP
            return True
        if sys.platform == "darwin":
            os.system("/usr/bin/osascript -e 'tell application \"System Events\" "
                      "to key code 107' >/dev/null 2>&1")   # F24 in AppleScript
            return True
    except Exception as e:      # 注入失败不影响主流程（下次按键时也会刷新）
        log(f"注入按键失败: {e}")
    return False


# ---------------------------------------------------------------- 文件协议
def read_request(path):
    """返回 (word, delay_ms) 或 (None, None)。"""
    try:
        with open(path, encoding="utf-8") as f:
            word = (f.readline() or "").strip()
            delay = (f.readline() or "").strip()
    except OSError:
        return None, None
    if not word:
        return None, None
    try:
        delay_ms = int(delay)
    except ValueError:
        delay_ms = None
    return word, delay_ms


def write_response(d, word, text):
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, "response.tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(word + "\n" + text + "\n")
    os.replace(tmp, os.path.join(d, "response.txt"))




def ai_dict_path(cfg):
    """AI 补录词库（人类可读的 Rime 词典文件）。"""
    p = cfg.get("ai_dict") or os.environ.get("RIME_AI_DICT")
    if p:
        return p
    if os.name == "nt":
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"),
                            "Rime", "dicts", "ai_ecdict.dict.yaml")
    return os.path.expanduser("~/Library/Rime/dicts/ai_ecdict.dict.yaml")


DICT_HEADER = """# Rime dictionary
# encoding: utf-8
#v%d
#
# AI 补录词库（英文模式）—— 由 ai_bridge.py 自动追加，也可手工删改
# 格式：文本 <TAB> 编码 <TAB> 权重
---
name: ai_ecdict
version: "0.1"
sort: by_weight
use_preset_vocabulary: false
...
"""


def read_ai_dict(path):
    """{word: {"meaning": 显示文本, "cap": bool}}，直接解析 dict.yaml（可手工改）。"""
    words = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or "\t" not in line:
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 3:
                    continue
                text, code = cols[0], cols[1]
                e = words.setdefault(code, {"meaning": "", "cap": False})
                if text == code:
                    continue
                if not e["meaning"]:
                    e["meaning"] = text
                if code[:1].isupper():
                    e["cap"] = True
    except OSError:
        pass
    return words


def write_ai_dict(path, words):
    """words: {word: {"meaning","cap"}} → 整份重写（带 #v<ts> 版本标记，lua 靠它重读）。"""
    lines = []
    for w in sorted(words):
        e = words[w]
        meaning = (e.get("meaning") or "").strip()
        lines.append("%s\t%s\t10" % (w, w))
        if meaning and meaning != w:
            lines.append("%s\t%s\t0" % (meaning, w))
        if e.get("cap"):
            cap = w[:1].upper() + w[1:]
            if cap != w:
                lines.append("%s\t%s\t10" % (cap, cap))
                if meaning:
                    lines.append("%s\t%s\t0" % (meaning, cap))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(DICT_HEADER % int(time.time()))
        f.write("\n".join(lines) + ("\n" if lines else ""))
    os.replace(tmp, path)


def save_word(ai_path, word, entry):
    """把 AI 结果并进 ai_ecdict.dict.yaml（同词覆盖），保留人工改动。"""
    if not ai_path:
        return False
    words = read_ai_dict(ai_path)
    meaning = ((entry.get("pos", "") + " " + entry["zh"]).strip()
               if entry.get("pos") else entry["zh"])
    meaning = short_zh(meaning)
    words[word] = {"meaning": meaning, "cap": bool(entry.get("cap"))}
    try:
        os.makedirs(os.path.dirname(ai_path) or ".", exist_ok=True)
        write_ai_dict(ai_path, words)
        return True
    except OSError as e:
        log(f"写入 {ai_path} 失败: {e}")
        return False


def load_cache(d):
    try:
        with open(os.path.join(d, "cache.json"), encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    out = {}
    for k, v in (raw or {}).items():
        e = normalize_entry(v)
        if e:
            out[k] = e
    return out


def save_cache(d, cache):
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "cache.json"), "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False)
    except OSError:
        pass


def default_local_dicts():
    base = (os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "Rime")
            if os.name == "nt" else os.path.expanduser("~/Library/Rime"))
    return [os.path.join(base, n) for n in ("dicts/ecdict.dict.yaml", "dicts/chem_ecdict.dict.yaml", "dicts/ai_ecdict.dict.yaml")]


def load_local_words(cfg):
    """ecdict + ai_ecdict 里的"原词"条目；用来判断这句还需不需要大模型。"""
    paths = cfg.get("local_dict") or default_local_dicts()
    if isinstance(paths, str):
        paths = [paths]
    words = set()
    read_any = False
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("#") or line.startswith("---"):
                        continue
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) == 3 and cols[0] == cols[1]:
                        words.add(cols[0])
            read_any = True
        except OSError:
            pass
    if not read_any:
        log("本地词库没读到，skip_local 失效")
        return None
    log(f"本地词库 {len(words)} 词（{len(paths)} 个文件）")
    return words


LOG_PATH = None


def rime_paths(cfg):
    """rime 安装目录 / 用户目录（各平台默认值，可被 config.json 覆盖）。"""
    rime_dir = cfg.get("rime_dir")
    user_dir = cfg.get("user_dir")
    if os.name == "nt":
        rime_dir = rime_dir or r"C:\Program Files\Rime\weasel-0.17.4"
        user_dir = user_dir or os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "Rime")
    elif sys.platform == "darwin":
        rime_dir = rime_dir or "/Library/Input Methods/Squirrel.app/Contents/MacOS"
        user_dir = user_dir or os.path.expanduser("~/Library/Rime")
    else:
        rime_dir = rime_dir or "/usr/bin"
        user_dir = user_dir or os.path.expanduser("~/.config/ibus/rime")
    return rime_dir, user_dir


def ime_restart(cfg):
    """让输入法重新加载 lua 模块（librime-lua 每个 engine 会话只加载一次）。"""
    rime_dir, _ = rime_paths(cfg)
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/IM", "WeaselServer.exe", "/F"],
                           capture_output=True, creationflags=CREATE_NO_WINDOW)
            time.sleep(0.8)
            exe = os.path.join(rime_dir, "WeaselServer.exe")
            subprocess.Popen([exe], cwd=rime_dir, close_fds=True,
                             stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL,
                             creationflags=DETACHED_PROCESS)
        elif sys.platform == "darwin":
            subprocess.run([os.path.join(rime_dir, "Squirrel"), "--reload"], capture_output=True)
        else:
            subprocess.run(["ibus", "restart"], capture_output=True)
        return True
    except OSError as e:
        log(f"重启输入法失败: {e}")
        return False


def ime_deploy(cfg):
    """重新部署（改 yaml 后需要）。"""
    rime_dir, _ = rime_paths(cfg)
    try:
        if os.name == "nt":
            subprocess.run([os.path.join(rime_dir, "WeaselDeployer.exe"), "/deploy"],
                           capture_output=True, creationflags=CREATE_NO_WINDOW)
        elif sys.platform == "darwin":
            subprocess.run([os.path.join(rime_dir, "Squirrel"), "--reload"], capture_output=True)
        else:
            subprocess.run(["ibus", "restart"], capture_output=True)
        return True
    except OSError as e:
        log(f"部署失败: {e}")
        return False


# 只有这两类文件才需要"重新部署"；user.yaml / installation.yaml / *.dict.yaml
# 都是运行时数据（部署本身就会改 user.yaml，ai_ecdict 是桥自己写的），盯它们会自激
WATCH_SUFFIXES = (".custom.yaml", ".schema.yaml", ".dict.yaml")
# 桥自己会写这两个，盯它们会自激
WATCH_IGNORE = {"ai_ecdict.dict.yaml"}


def watch_loop(cfg):
    """盯 lua/ 和 *.yaml：lua 变了就重启输入法，yaml 变了就重新部署。

    所以不需要额外的部署/重载脚本。"""
    _, user_dir = rime_paths(cfg)
    lua_dir = os.path.join(user_dir, "lua")
    seen = {}
    for path in snapshot(lua_dir, ".lua") + config_snapshot(user_dir):
        seen[path] = os.path.getmtime(path)
    settle = 3.0          # 改动停止 3 秒后才动手，避免边存边部署
    cooldown = 0.0        # 自己刚动过手，冷却期内忽略（防自激）
    log("监听 lua/*.lua 与 *.custom/schema/dict.yaml（改完自动部署/重载）")
    while True:
        time.sleep(1.0)
        lua_changed = yaml_changed = False
        fresh = {}
        for path in snapshot(lua_dir, ".lua"):
            mt = os.path.getmtime(path)
            fresh[path] = mt
            if seen.get(path) not in (None, mt):
                lua_changed = True
        for path in config_snapshot(user_dir):
            mt = os.path.getmtime(path)
            fresh[path] = mt
            if seen.get(path) not in (None, mt):
                yaml_changed = True
        seen = fresh
        if time.time() < cooldown:
            continue
        if not (lua_changed or yaml_changed):
            continue
        time.sleep(settle)                     # 等用户存完盘
        if lua_changed:
            log("检测到 lua 改动 → 重启输入法以重载模块")
            ime_restart(cfg)
        if yaml_changed:
            log("检测到 yaml 改动 → 重新部署")
            ime_deploy(cfg)
            if lua_changed:
                time.sleep(1.0)
                ime_restart(cfg)
        cooldown = time.time() + 10          # 部署会改 user.yaml，别被自己触发
        seen = {p: os.path.getmtime(p)
                for p in snapshot(lua_dir, ".lua") + config_snapshot(user_dir)}


def config_snapshot(user_dir):
    out = []
    for suffix in WATCH_SUFFIXES:
        for path in snapshot(user_dir, suffix):
            if os.path.basename(path) not in WATCH_IGNORE:
                out.append(path)
    return out


def snapshot(directory, suffix):
    out = []
    try:
        for name in os.listdir(directory):
            if name.endswith(suffix):
                out.append(os.path.join(directory, name))
    except OSError:
        pass
    return out


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(f"[rime-en-ai] {msg}", file=sys.stderr, flush=True)
    if LOG_PATH:
        try:
            if os.path.isfile(LOG_PATH) and os.path.getsize(LOG_PATH) > 1_000_000:
                os.replace(LOG_PATH, LOG_PATH + ".1")
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


# ---------------------------------------------------------------- 主循环
def marquee_loop(cfg, d):
    """跑马灯：lua 写 marquee.txt 表示"有长释义在显示"，这里按 tick_ms 注入 F24 让它滚动。
    lua 在用户按非字母键（上下键/数字/空格）时会写 marquee_pause.txt，暂停 1.5 秒，
    避免重绘把候选选中项重置掉。"""
    flag = os.path.join(d, "marquee.txt")
    pause = os.path.join(d, "marquee_pause.txt")
    tick = max(60, int(cfg.get("tick_ms", 200))) / 1000.0
    running = False
    ticks = 0
    last_report = 0.0
    while True:
        try:
            fresh = time.time() - os.path.getmtime(flag) < max(0.9, tick * 3)
        except OSError:
            fresh = False
        paused = (os.path.isfile(pause)
                  and time.time() - os.path.getmtime(pause) < 1.5)
        if fresh and not paused:
            ok = inject_refresh()
            ticks += 1
            if not running:
                running = True
                ticks = 1
                log("跑马灯开始滚动" + ("" if ok else "（注入失败！）"))
            elif time.time() - last_report > 2:
                last_report = time.time()
                log(f"跑马灯滚动中… 已注入 {ticks} 次 F24")
        elif running:
            running = False
            log(f"跑马灯停止（共注入 {ticks} 次）")
        time.sleep(tick)


def serve(cfg, fallback_delay):
    global LOG_PATH
    d = bridge_dir(cfg)
    os.makedirs(d, exist_ok=True)
    req = os.path.join(d, "request.txt")
    cache = load_cache(d)
    LOG_PATH = os.path.join(d, "bridge.log")     # 开机自启时（pythonw 无控制台）也能查日志
    log(f"bridge 启动，dir: {d}")
    if cfg.get("_source"):
        log(f"config: {cfg['_source']}")
    else:
        log("⚠ 没找到 config.json，只做本地缓存回放（不会调 API）")

    words = load_local_words(cfg) if cfg.get("skip_local", True) else None
    do_save = cfg.get("save", True)
    ai_path = ai_dict_path(cfg)
    saved = read_ai_dict(ai_path)
    try:
        ai_mtime = os.path.getmtime(ai_path) if os.path.isfile(ai_path) else 0
    except OSError:
        ai_mtime = 0
    if saved:
        log(f"AI 词库已有 {len(saved)} 词：{ai_path}")
    try:
        if sync_schema(cfg) or needs_deploy(cfg):
            log("档位/schema 有变化 → 重新部署")
            ime_deploy(cfg)
    except OSError as e:
        log(f"同步档位到 schema 失败: {e}")
    names = list((cfg.get("profiles") or {}).keys())
    if names:
        log("AI 档位: " + ", ".join(names) + f"（当前 {cfg.get('active') or names[0]}）")

    if cfg.get("watch", True):
        threading.Thread(target=watch_loop, args=(cfg,), daemon=True).start()

    if cfg.get("marquee_auto", False):
        threading.Thread(target=marquee_loop, args=(cfg, d), daemon=True).start()
        log(f"跑马灯已启用（tick {cfg.get('tick_ms', 200)}ms）")

    last_word = None
    pending_word = None
    due = 0.0
    done_word = None
    min_len = int(cfg.get("min_input_len", 2))

    # config.json 改动后自动重载，不用重启桥
    cfg_src = cfg.get("_source")
    cfg_mtime = os.path.getmtime(cfg_src) if cfg_src and os.path.isfile(cfg_src) else None
    last_cfg_check = 0.0

    while True:
        word, delay_ms = read_request(req)
        now = time.time()
        try:                 # IME 里按了「切换 AI」→ 读档位
            pf = os.path.join(d, "ai_profile.txt")
            if os.path.isfile(pf):
                want = open(pf, encoding="utf-8").read().strip()
                if want and want != (cfg.get("active") or ""):
                    cfg["active"] = want
                    log(f"已切换 AI：{want}")
        except OSError:
            pass
        try:                 # 词库被删词改过 → 重读，别把它又写回去
            mt = os.path.getmtime(ai_path) if os.path.isfile(ai_path) else 0
            if mt != ai_mtime:
                ai_mtime = mt
                saved = read_ai_dict(ai_path)
                log(f"AI 词库已更新（{len(saved)} 词）")
        except OSError:
            pass
        if cfg_src and now - last_cfg_check > 1:
            last_cfg_check = now
            try:
                mt = os.path.getmtime(cfg_src)
            except OSError:
                mt = None
            if mt and cfg_mtime and mt != cfg_mtime:
                cfg_mtime = mt
                try:
                    cfg = load_config(cfg_src)
                    words = load_local_words(cfg) if cfg.get("skip_local", True) else None
                    try:
                        if sync_schema(cfg):
                            log("档位列表有变化 → 重新部署")
                            ime_deploy(cfg)
                    except OSError as e:
                        log(f"同步档位到 schema 失败: {e}")
                    log("config.json 已改动，重载完成")
                except Exception as e:      # 配置写坏了不要拖垮桥
                    log(f"配置重载失败（继续用旧的）: {e}")
        if word != last_word:
            last_word = word
            pending_word = word if (word and len(word) >= min_len) else None
            wait = (delay_ms if delay_ms is not None else cfg.get("delay_ms", fallback_delay))
            due = now + max(0, int(wait)) / 1000.0

        if pending_word and now >= due and pending_word != done_word:
            word_to_do = pending_word
            pending_word = None
            done_word = word_to_do
            if word_to_do in saved:
                log(f"{word_to_do} 已在 AI 词库，直接回放")
                write_response(d, word_to_do, saved[word_to_do]["meaning"] or word_to_do)
                inject_refresh()
                continue
            if words is not None and word_to_do in words:
                log(f"{word_to_do} 本地已有释义，跳过 API")
                continue
            effective = active_profile(cfg)
            entry = normalize_entry(cache.get(word_to_do)) or translate(effective, word_to_do)
            if entry:
                if cache.get(word_to_do) != entry:
                    cache[word_to_do] = entry
                    save_cache(d, cache)
                write_response(d, word_to_do, display_text(entry))
                inject_refresh()
                log(f"{word_to_do} -> {display_text(entry)}")
                if do_save and save_word(ai_path, word_to_do, entry):
                    saved[word_to_do] = {"meaning": display_text(entry), "cap": entry.get("cap", False)}
                    log(f"已写入 AI 词库（共 {len(saved)} 词）：{ai_path}")

        time.sleep(POLL_SEC)


# ---------------------------------------------------------------- 自测
def selftest():
    from http.server import BaseHTTPRequestHandler, HTTPServer

    hits = []

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers["Content-Length"])
            body = json.loads(self.rfile.read(n))
            hits.append(body)
            out = json.dumps({"choices": [{"message": {"content": "你好；喂"}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}/v1/chat/completions"

    cfg = {"base_url": base, "model": "test", "api_key": "k"}
    got = translate(cfg, "hello")
    assert got["zh"] == "你好；喂", got
    assert hits and hits[0]["messages"][-1]["content"] == "hello", hits

    # 自定义模板 + 自定义响应路径
    class H2(H):
        def do_POST(self):
            n = int(self.headers["Content-Length"])
            body = json.loads(self.rfile.read(n))
            out = json.dumps({"data": {"translation": "树"}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    srv2 = HTTPServer(("127.0.0.1", 0), H2)
    threading.Thread(target=srv2.serve_forever, daemon=True).start()
    cfg2 = {
        "base_url": f"http://127.0.0.1:{srv2.server_port}/t",
        "request_template": '{"q": "{text}"}',
        "response_path": "data.translation",
    }
    assert translate(cfg2, "tree")["zh"] == "树"

    # 请求/响应文件协议
    with tempfile.TemporaryDirectory() as d:
        req = os.path.join(d, "request.txt")
        with open(req, "w", encoding="utf-8") as f:
            f.write("hello\n900\n0\n")
        assert read_request(req) == ("hello", 900)
        write_response(d, "hello", "你好")
        with open(os.path.join(d, "response.txt"), encoding="utf-8") as f:
            assert f.read() == "hello\n你好\n"

    with tempfile.TemporaryDirectory() as d:
        dict_path = os.path.join(d, "ecdict.dict.yaml")
        with open(dict_path, "w", encoding="utf-8") as f:
            f.write("---\nname: ecdict\n...\n")
            f.write("hello\thello\t10\n")
            f.write("interj. 喂, 嘿\thello\t0\n")
            f.write("world\tworld\t10\n")
        words = load_local_words({"local_dict": dict_path})
        assert words == {"hello", "world"}, words

    # Anthropic / MiniMax 形状：content 里先有 thinking 块，再是 text 块
    body = {"id": "x", "type": "message", "role": "assistant", "model": "m",
            "content": [{"type": "thinking", "thinking": "let me think..."},
                        {"type": "text", "text": "名词；类型"}]}
    assert extract_text(body) == "名词；类型", extract_text(body)
    assert extract_text({"choices": [{"message": {"content": "喂"}}]}) == "喂"
    assert api_kind({"base_url": "https://api.minimax.cn/anthropic/v1/messages"}) == "anthropic"
    assert api_kind({"base_url": "https://api.openai.com/v1/chat/completions"}) == "openai"
    assert "system" in build_payload({"model": "m", "prompt": "p"}, "hi", "anthropic")

    with tempfile.TemporaryDirectory() as d:
        target = os.path.join(d, "ai_ecdict.dict.yaml")
        assert save_word(target, "typst", {"zh": "排版系统", "pos": "n.", "cap": True})
        assert save_word(target, "hello", {"zh": "喂", "pos": "int.", "cap": False})
        assert save_word(target, "typst", {"zh": "排版系统v2", "pos": "n.", "cap": True})  # 同词覆盖
        got = read_ai_dict(target)
        assert got["typst"]["meaning"] == "n. 排版系统v2", got["typst"]
        assert got["hello"]["meaning"] == "int. 喂"
        body = open(target, encoding="utf-8").read()
        assert "#v" in body and "name: ai_ecdict" in body
        assert body.count("n. 排版系统v2") == 2, body   # typst + Typst 各一条

    assert parse_result('{"zh":"喂","pos":"int.","cap":false}') == {"zh": "喂", "pos": "int.", "cap": False}
    assert parse_result('```json\n{"zh":"树","pos":"n."}\n```')["zh"] == "树"
    assert parse_result("只是个普通释义") == {"zh": "只是个普通释义", "pos": "", "cap": False}
    assert display_text({"zh": "电脑", "pos": "n."}) == "n. 电脑"


    cfg_multi = {"active": "b", "timeout": 9,
                 "profiles": {"a": {"base_url": "http://a"}, "b": {"base_url": "http://b", "model": "m2"}}}
    eff = active_profile(cfg_multi)
    assert eff["base_url"] == "http://b" and eff["model"] == "m2" and eff["timeout"] == 9, eff
    assert eff["_profile"] == "b"
    assert active_profile({"base_url": "http://x"})["_profile"] == "default"

    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config")
    ap.add_argument("--once", metavar="WORD", help="只查一个词")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--delay", type=int, default=900)
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    moved = migrate_config()
    if moved:
        print(f"[rime-en-ai] 配置已迁移: {moved}", file=sys.stderr)
    cfg = load_config(args.config)
    if args.once:
        entry = translate(active_profile(cfg), args.once)
        if not entry:
            print("(失败)")
            return
        print(display_text(entry))
        print("  zh  = " + entry["zh"])
        print("  pos = " + (entry["pos"] or "(空)"))
        print("  cap = " + str(entry["cap"]))
        return
    serve(cfg, args.delay)


if __name__ == "__main__":
    main()
