#!/usr/bin/env python3
"""用 librime 自己的 C API 模拟按键，验证词库 / 方案的真实行为。

不弹窗、不抢焦点、不写用户词典（只读），所以适合在改完词库或 lua 之后跑一遍。

    python scripts/probe.py Hello LaTeX typ        # 看候选 + 释义
    python scripts/probe.py --commit Hello         # 看上屏文本（自动补一个空格）
    python scripts/probe.py --pages 0 Hello        # 翻到底，看完整候选列表
    python scripts/probe.py --check                # 冒烟断言（改完东西跑这个）

平台：Windows 用 Weasel 自带的 rime.dll（自动找），macOS / Linux 用 RIME_LIB 指路：

    RIME_LIB=/Library/Input\\ Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib \\
    python3 scripts/probe.py --check

输出里的 `level_db.cc ... LOCK` 之类是输入法正开着、用户词典被占用，属正常噪音；
想看 lua 报错就加 --verbose。
"""
import argparse
import ctypes as C
import glob
import os
import sys
import time

# ---------------------------------------------------------------- 库与目录

HERE = os.path.dirname(os.path.abspath(__file__))


def find_library():
    env = os.environ.get("RIME_LIB")
    if env:
        return env
    if os.name == "nt":
        for pat in (r"C:\Program Files\Rime\weasel-*\rime.dll",
                    r"C:\Program Files (x86)\Rime\weasel-*\rime.dll"):
            hits = sorted(glob.glob(pat))
            if hits:
                return hits[-1]
    for pat in ("/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime*.dylib",
                os.path.expanduser("~/Library/Rime/librime*.dylib"),
                "/usr/lib/**/librime.so*", "/usr/local/lib/librime.so*",
                "/opt/homebrew/lib/librime*.dylib"):
        hits = sorted(glob.glob(pat, recursive=True))
        if hits:
            return hits[0]
    return None


def find_shared_dir(lib):
    env = os.environ.get("RIME_SHARED_DIR")
    if env:
        return env
    if os.name == "nt" and lib:
        cand = os.path.join(os.path.dirname(lib), "data")
        if os.path.isdir(cand):
            return cand
    for cand in ("/Library/Input Methods/Squirrel.app/Contents/SharedSupport",
                 "/usr/share/rime-data", "/usr/local/share/rime-data"):
        if os.path.isdir(cand):
            return cand
    return None


def find_user_dir():
    env = os.environ.get("RIME_USER_DIR")
    if env:
        return env
    if os.name == "nt":
        return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "Rime")
    for cand in ("~/Library/Rime", "~/.config/ibus/rime", "~/.local/share/fcitx5/rime"):
        p = os.path.expanduser(cand)
        if os.path.isdir(p):
            return p
    return os.path.expanduser("~/Library/Rime")


# ---------------------------------------------------------------- C 结构
# 与 librime/src/rime_api.h 保持一致（只用到其中几个，其余按指针占位）。
# 顺序不能动：RimeApi 是函数指针表，偏移错了就会崩。

API_FIELDS = """data_size setup set_notification_handler initialize finalize
start_maintenance is_maintenance_mode join_maintenance_thread deployer_initialize
prebuild deploy deploy_schema deploy_config_file sync_user_data create_session
find_session destroy_session cleanup_stale_sessions cleanup_all_sessions process_key
commit_composition clear_composition get_commit free_commit get_context free_context
get_status free_status set_option get_option set_property get_property get_schema_list
free_schema_list get_current_schema select_schema schema_open config_open config_close
config_get_bool config_get_int config_get_double config_get_string config_get_cstring
config_update_signature config_begin_map config_next config_end simulate_key_sequence
register_module find_module run_task get_shared_data_dir get_user_data_dir get_sync_dir
get_user_id get_user_data_sync_dir config_init config_load_string config_set_bool
config_set_int config_set_double config_set_string config_get_item config_set_item
config_clear config_create_list config_create_map config_list_size config_begin_list
get_input get_caret_pos select_candidate get_version set_caret_pos
select_candidate_on_current_page candidate_list_begin candidate_list_next
candidate_list_end user_config_open candidate_list_from_index get_prebuilt_data_dir
get_staging_dir commit_proto context_proto status_proto get_state_label delete_candidate
delete_candidate_on_current_page get_state_label_abbreviated set_input
get_shared_data_dir_s get_user_data_dir_s get_prebuilt_data_dir_s get_staging_dir_s
get_sync_dir_s highlight_candidate highlight_candidate_on_current_page change_page
get_candidate_preview free_candidate_preview""".split()


class Traits(C.Structure):
    _fields_ = [("data_size", C.c_int),
                ("shared_data_dir", C.c_char_p), ("user_data_dir", C.c_char_p),
                ("distribution_name", C.c_char_p), ("distribution_code_name", C.c_char_p),
                ("distribution_version", C.c_char_p), ("app_name", C.c_char_p),
                ("modules", C.POINTER(C.c_char_p)), ("min_log_level", C.c_int),
                ("log_dir", C.c_char_p), ("prebuilt_data_dir", C.c_char_p),
                ("staging_dir", C.c_char_p)]


class Composition(C.Structure):
    _fields_ = [("length", C.c_int), ("cursor_pos", C.c_int), ("sel_start", C.c_int),
                ("sel_end", C.c_int), ("preedit", C.c_char_p)]


class Candidate(C.Structure):
    _fields_ = [("text", C.c_char_p), ("comment", C.c_char_p), ("reserved", C.c_void_p)]


class Menu(C.Structure):
    _fields_ = [("page_size", C.c_int), ("page_no", C.c_int), ("is_last_page", C.c_int),
                ("highlighted_candidate_index", C.c_int), ("num_candidates", C.c_int),
                ("candidates", C.POINTER(Candidate)), ("select_keys", C.c_char_p)]


class Context(C.Structure):
    _fields_ = [("data_size", C.c_int), ("composition", Composition), ("menu", Menu),
                ("commit_text_preview", C.c_char_p), ("select_labels", C.POINTER(C.c_char_p))]


class Commit(C.Structure):
    _fields_ = [("data_size", C.c_int), ("text", C.c_char_p)]


SIG = {
    "setup": (None, [C.POINTER(Traits)]),
    "initialize": (C.c_int, [C.POINTER(Traits)]),
    "finalize": (None, []),
    "create_session": (C.c_size_t, []),
    "destroy_session": (C.c_int, [C.c_size_t]),
    "select_schema": (C.c_int, [C.c_size_t, C.c_char_p]),
    "simulate_key_sequence": (C.c_int, [C.c_size_t, C.c_char_p]),
    "get_context": (C.c_int, [C.c_size_t, C.POINTER(Context)]),
    "free_context": (C.c_int, [C.POINTER(Context)]),
    "clear_composition": (None, [C.c_size_t]),
    "change_page": (C.c_int, [C.c_size_t, C.c_int]),
    "get_commit": (C.c_int, [C.c_size_t, C.POINTER(Commit)]),
    "free_commit": (C.c_int, [C.POINTER(Commit)]),
}


class Api(C.Structure):
    _fields_ = [(n, C.c_int) if n == "data_size" else
                (n, C.CFUNCTYPE(SIG[n][0], *SIG[n][1]) if n in SIG else C.c_void_p)
                for n in API_FIELDS]


# ---------------------------------------------------------------- 会话


class Rime:
    def __init__(self, schema="english", verbose=False, log_dir=None):
        lib = find_library()
        if not lib or not os.path.exists(lib):
            raise SystemExit("找不到 librime（rime.dll / librime.so）。用 RIME_LIB=... 指路。")
        shared = find_shared_dir(lib)
        user = find_user_dir()
        if not shared:
            raise SystemExit("找不到共享数据目录，用 RIME_SHARED_DIR=... 指路。")
        self.lib = C.CDLL(lib)
        self.lib.rime_get_api.restype = C.POINTER(Api)
        self.api = self.lib.rime_get_api().contents

        t = Traits()
        t.data_size = C.sizeof(Traits)
        t.shared_data_dir = shared.encode()
        t.user_data_dir = user.encode()
        t.distribution_name = b"Rime"
        t.distribution_code_name = b"rime"
        t.distribution_version = b"0"
        t.app_name = b"rime.probe"
        t.min_log_level = 2 if verbose else 3      # 3 = FATAL，把锁文件之类的噪音压掉
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
            t.log_dir = log_dir.encode()
        self._traits = t

        if self.api.setup:
            self.api.setup(C.byref(t))
        self.api.initialize(C.byref(t))

        self.sid = self.api.create_session()
        if not self.sid:
            raise SystemExit("create_session 失败")
        if not self.api.select_schema(self.sid, schema.encode()):
            raise SystemExit(f"select_schema({schema}) 失败：这个方案还没部署？")

    def close(self):
        self.api.destroy_session(self.sid)
        self.api.finalize()

    def type_and_read(self, keys):
        """打一串键，然后读候选 —— **不**重置组合（--auto 还要接着等桥返回）。"""
        self.api.clear_composition(self.sid)
        self.api.simulate_key_sequence(self.sid, keys.encode())
        c = self._ctx()
        if c is None:
            return "", [], 0
        preedit = c.composition.preedit.decode() if c.composition.preedit else ""
        out = [((c.menu.candidates[i].text or b"").decode(),
                (c.menu.candidates[i].comment or b"").decode(),
                i == c.menu.highlighted_candidate_index)
               for i in range(c.menu.num_candidates)]
        page_size = c.menu.page_size
        self.api.free_context(C.byref(c))
        return preedit, out, page_size

    def refresh_and_read(self):
        """在同一个组合里敲 F24（lua 收到就重绘），然后读候选，不重置组合。"""
        self.api.simulate_key_sequence(self.sid, b"{F24}")
        c = self._ctx()
        if c is None:
            return "", [], 0
        preedit = c.composition.preedit.decode() if c.composition.preedit else ""
        out = [((c.menu.candidates[i].text or b"").decode(),
                (c.menu.candidates[i].comment or b"").decode(),
                i == c.menu.highlighted_candidate_index)
               for i in range(c.menu.num_candidates)]
        page_size = c.menu.page_size
        self.api.free_context(C.byref(c))
        return preedit, out, page_size

    def _ctx(self):
        c = Context()
        c.data_size = C.sizeof(Context)
        if not self.api.get_context(self.sid, C.byref(c)):
            return None
        return c

    def candidates(self, keys, pages=1):
        """按键 → (preedit, [(text, comment, highlighted)], page_size)。pages>1 会翻页。"""
        self.api.clear_composition(self.sid)
        self.api.simulate_key_sequence(self.sid, keys.encode())
        out, preedit, page_size = [], "", 0
        limit = 20 if pages <= 0 else pages        # --pages 0 = 翻到底
        for page in range(limit):
            c = self._ctx()
            if c is None:
                break
            preedit = c.composition.preedit.decode() if c.composition.preedit else ""
            page_size = c.menu.page_size
            for i in range(c.menu.num_candidates):
                cand = c.menu.candidates[i]
                out.append(((cand.text or b"").decode(),
                            (cand.comment or b"").decode(),
                            i == c.menu.highlighted_candidate_index and page == 0))
            last = c.menu.is_last_page
            self.api.free_context(C.byref(c))
            if last or not self.api.change_page:
                break
            self.api.change_page(self.sid, 0)
        self.api.clear_composition(self.sid)
        return preedit, out, page_size

    def commit(self, keys):
        """按键 → 上屏的文本（没上屏返回 None）。"""
        self.api.clear_composition(self.sid)
        self.api.simulate_key_sequence(self.sid, keys.encode())
        c = Commit()
        c.data_size = C.sizeof(Commit)
        if self.api.get_commit(self.sid, C.byref(c)) and c.text:
            text = c.text.decode()
            self.api.free_commit(C.byref(c))
            self.api.clear_composition(self.sid)
            return text
        self.api.clear_composition(self.sid)
        return None


# ---------------------------------------------------------------- 命令


def cmd_words(rime, words, pages):
    ok = True
    for w in words:
        preedit, cands, page_size = rime.candidates(w, pages=pages)
        print(f"\n--- {w!r}   preedit={preedit!r}  候选 {len(cands)} 条  每页 {page_size}")
        if not cands:
            print("    （没有候选：词库里没有，也不在 AI 词库 / response.txt 里）")
            ok = False
        for i, (text, comment, hl) in enumerate(cands, 1):
            flag = "  <<<" if hl else ""
            print(f"   {i}. {text!r}   comment={comment!r}{flag}")
    return 0 if ok else 1


def cmd_commit(rime, words):
    ok = True
    for w in words:
        got = rime.commit(w + " ")
        if got is None:
            print(f"  上屏 {w + ' '!r} -> (没有上屏)")
            ok = False
        else:
            print(f"  上屏 {w + ' '!r} -> {got!r}")
            if w[:1].isupper() and got[:1].islower():
                print("     ↑ 首字母大写没补回来（看 lua/en_space.lua）")
                ok = False
    return 0 if ok else 1


def cmd_auto(rime, word, seconds):
    """模拟打字 → 停手 → 看常驻桥有没有把 AI 释义补上来（会真的调一次 API）。

    桥返回后用全局 F24 触发重绘，但那个按键是发给前台窗口的，进不了这个探测会话，
    所以这里在会话里自己再敲一次 F24（lua 收到 F24 就重绘候选）。
    """
    print(f"  打字 {word!r}，然后等 {seconds}s（桥：停手 delay_ms → 请求 API → 写回）...")
    preedit, cands, _ = rime.type_and_read(word)
    print(f"  等之前：preedit={preedit!r} 候选 {len(cands)} 条"
          + (f"，comment={cands[0][1]!r}" if cands else ""))
    time.sleep(seconds)
    preedit, cands, _ = rime.refresh_and_read()
    print(f"  等之后：候选 {len(cands)} 条")
    ok = False
    for i, (text, comment, hl) in enumerate(cands, 1):
        print(f"   {i}. {text!r}   comment={comment!r}{'  <<<' if hl else ''}")
        if comment:
            ok = True
    if not ok:
        print("  没有释义：桥没跑？没配 api_key？还是 delay_ms 还没到？看 bridge.log")
    return 0 if ok else 1


def cmd_check(rime):
    """改完词库/方案跑这个：几条最基本的行为必须成立。"""
    fails = []

    def want(cond, msg):
        print(("  [PASS] " if cond else "  [FAIL] ") + msg)
        if not cond:
            fails.append(msg)

    # 小写词：有候选 + 有释义
    _, cands, _ = rime.candidates("hello")
    want(bool(cands), "hello 有候选（词库没丢？部署了吗？）")
    if cands:
        want(cands[0][0] == "hello", f"hello 的第一个候选是 hello（实际 {cands[0][0]!r}）")
        want(bool(cands[0][1]), f"hello 带释义（实际 {cands[0][1]!r}）")

    # 首字母大写：靠 speller/algebra 派生，词库里没有大写条目
    _, cands_cap, _ = rime.candidates("Hello")
    want(bool(cands_cap), "Hello 有候选（schema 的 speller/algebra 生效？）")
    if cands_cap:
        want(bool(cands_cap[0][1]), f"Hello 带释义（实际 {cands_cap[0][1]!r}）")

    # 上屏：补空格 + 首字母大写回填
    got = rime.commit("hello ")
    want(got == "hello ", f"上屏 hello␣ -> 'hello '（实际 {got!r}）")
    got = rime.commit("Hello ")
    want(got == "Hello ", f"上屏 Hello␣ -> 'Hello '（实际 {got!r}）")

    # 词库里没有的词：filter 补一条候选，且注释是空串而不是 nil
    got = rime.commit("zzzqqq ")
    want(got is not None, "词库没有的词也能上屏（filter 的补候选没崩）")

    # 释义行不能被当成候选词（隐形标记 \x01 是否生效）
    _, cands, _ = rime.candidates("info")
    texts = [t for t, _, _ in cands]
    want(all("\x01" not in t for t in texts), "候选里没有残留的释义标记")
    want(all(not t.startswith("n. ") for t in texts), "释义没有被当成候选词")

    print("")
    if fails:
        print(f"{len(fails)} 项失败")
        return 1
    print("全部通过")
    return 0


def main():
    ap = argparse.ArgumentParser(description="用 librime 模拟按键，验证输入法的真实行为")
    ap.add_argument("words", nargs="*", help="要试的输入（可以给多个）")
    ap.add_argument("--schema", default="english", help="方案 id（默认 english）")
    ap.add_argument("--commit", action="store_true", help="看上屏文本（自动补一个空格）")
    ap.add_argument("--pages", type=int, default=1, help="翻几页；0 = 翻到底（默认 1）")
    ap.add_argument("--check", action="store_true", help="跑冒烟断言")
    ap.add_argument("--auto", type=float, metavar="秒", default=0,
                    help="打字后等 N 秒，验证桥自动补 AI 释义（会真的调一次 API）")
    ap.add_argument("--verbose", action="store_true", help="显示 librime 的 ERROR 日志")
    args = ap.parse_args()

    rime = Rime(args.schema, verbose=args.verbose)
    try:
        if args.check:
            return cmd_check(rime)
        if args.auto:
            if not args.words:
                ap.error("--auto 需要一个词")
            return cmd_auto(rime, args.words[0], args.auto)
        if not args.words:
            ap.print_help()
            return 2
        if args.commit:
            return cmd_commit(rime, args.words)
        return cmd_words(rime, args.words, args.pages)
    finally:
        rime.close()


if __name__ == "__main__":
    sys.exit(main())
