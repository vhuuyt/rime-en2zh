#!/usr/bin/env python3
"""查询本地词库里有没有某个英文词（不启动输入法）。

    python scripts\\lookup.py hello computer typst

没命中的词就是"查不到"的直接原因：不在 2 万词表里，只能当普通英文上屏，
或者需要 --limit 重新生成词库。
"""
import os
import sys


def dict_paths():
    """基库 ecdict + AI 补录库 ai_ecdict，两个都查。"""
    root = os.environ.get("RIME_USER_DIR")
    if not root:
        root = (os.path.join(os.environ.get("APPDATA", ""), "Rime") if os.name == "nt"
                else os.path.expanduser("~/Library/Rime"))
    return [os.path.join(root, n) for n in
            ("dicts/ecdict.dict.yaml", "dicts/chem_ecdict.dict.yaml", "dicts/ai_ecdict.dict.yaml")]


def load(path):
    entries = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or line.startswith("---") or "\t" not in line:
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 2:
                continue
            entries.setdefault(cols[1], []).append(cols[0])
    return entries


def main():
    words = sys.argv[1:] or ["hello"]
    entries = {}
    for path in dict_paths():
        if not os.path.isfile(path):
            print("跳过（不存在）: " + path)
            continue
        part = load(path)
        for w, texts in part.items():
            entries.setdefault(w, []).extend(texts)
        print("词库: %s (%d words)" % (path, len(part)))
    missing = 0
    for w in words:
        hits = entries.get(w)
        if not hits:
            print("  %-20s MISS  not in dict (will be typed as plain text)" % w)
            missing += 1
            continue
        print("  %-20s HIT   %d entries" % (w, len(hits)))
        for h in hits[:4]:
            print("      - %s" % h)
    return 0 if not missing else 2


if __name__ == "__main__":
    sys.exit(main())
