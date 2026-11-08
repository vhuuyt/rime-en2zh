#!/usr/bin/env python3
"""ECDICT (csv) -> Rime 词典 (ecdict.dict.yaml)

用法:
    python3 scripts/ecdict2dict.py --csv ../ecdict.csv --out ecdict.dict.yaml --limit 20000

词条结构（排序后候选按 weight 从高到低）:
    英文原词      code=原词  weight=10   -> 选中 = 上屏英文
    中文释义      code=原词  weight=0    -> 选中 = 上屏中文

数据源: https://github.com/skywind3000/ECDICT  (ecdict.csv, ~66MB/77万词条)
"""
import argparse
import csv
import os
import re
import time
import sys
from collections import OrderedDict

WORD_RE = re.compile(r"^[a-z][a-z'-]{0,19}$")

# ECDICT 里没打 [化] 标记、但化学/实验里高频的词，强制收录（它们的变形会跟着一起生成）
EXTRA_WORDS = """
titrate titrant titrand titration titrated esterify esterified esterification saponify saponification
oxidize oxidizer oxidant oxidise oxidised oxidising oxidization reduce reductase reductant
protonate protonation deprotonate deprotonation hydrolyze hydrolysed hydrolysing hydrolytic
catalyze catalysed catalyzing catalysis cocatalyst catalyzer
polymer polymerize polymerization polymerise copolymer monomer dimer trimer oligomer macromolecule
distill distillation distillate reflux sinter sintering anneal annealing quench quenching
elute eluent elution eluate aliquot buffer bufferize molality molarity normality volumetric
stoichiometric stoichiometry exothermic endothermic enthalpy entropy thermochemistry calorimetry
electronegativity electrophilic nucleophilic electrophile nucleophile nucleophilicity
intermediate radical carbocation carbanion enolate tautomer tautomerize resonance hybridization
chirality chiral enantiomer enantiomeric diastereomer racemic racemate stereochemistry
aromaticity aromatic aliphatic alicyclic heterocyclic cycloalkane substituent substitution
functionalization derivatize derivatization moiety stoichiometric precipitant supernatant
spectrophotometry spectrometry chromatograph chromatographic titration conductometric
electrolysis electrolytic electrochemical potentiometric voltammetry amperometric
crystallize crystallization recrystallization sublimation lyophilize lyophilization centrifugation
spectroscopy spectrometric photometric colorimetric titration titrimetric gravimetric
solvate solvation solvolysis dissociation associate ionization ionize
isotope isotopic radiolabel radiolysis photolysis pyrolysis thermolysis electrolysis
corrosion corrode oxidization anodize galvanize passivation
""".split()
NOISE_PREFIX = ("[网络]", "[网络俚语]", "【网络】")
MAX_MEANING_LEN = 34
SHORT_MEANING_LEN = 22      # 联想模式贴在候选尾部的释义上限（超出部分由跑马灯滚动）
FULL_LINES = 0              # 额外长释义的行数：0 = 每词只留一条（filter 只显示第一条，多写的会白占体积）

# 释义行的隐形标记：filter 靠它区分「单词行」和「释义行」，不用再猜权重或像不像英文单词。
# 正文在候选里显示前会被 lua 剥掉，所以你看不到它。
MEANING_MARK = "\x01"


def parse_rank(row):
    """数字越小越常用；常用度 = min(frq, bnc)，没排名的排到最后。"""
    ranks = []
    for col in ("frq", "bnc"):
        v = (row.get(col) or "").strip()
        if v.isdigit() and int(v) > 0:
            ranks.append(int(v))
    r = min(ranks) if ranks else 10 ** 9
    collins = (row.get("collins") or "").strip()
    if collins.isdigit() and int(collins) > 0:
        r -= 20000 * int(collins)          # 柯林斯星级词往前放
    if (row.get("oxford") or "").strip() in ("1", "y", "Y"):
        r -= 20000
    return r


POS_RE = re.compile(r"^([a-z]{1,6}\.)\s*", re.I)


def split_pos(seg):
    m = POS_RE.match(seg)
    if not m:
        return "", seg
    return m.group(1), seg[m.end():]


def brief(segments, limit):
    """压出一条短释义：词性 + 尽量完整的义项（整条塞，不硬切单词）。"""
    if not segments:
        return ""
    pos, first = split_pos(segments[0])
    budget = limit - (len(pos) + 1 if pos else 0)

    # 把每个义项摊平
    senses = []
    for seg in segments:
        _, text = split_pos(seg)
        for part in text.split("；"):
            part = part.strip(" ，,；;")
            if part:
                senses.append(part)
    if not senses:
        return pos

    body = ""
    for sense in senses:
        nxt = sense if not body else body + "；" + sense
        if len(nxt) > budget:
            break
        body = nxt
    if not body:                      # 第一条就超长：切在预算内并加省略号
        body = senses[0][: max(4, budget - 1)].rstrip("，,；;、 ") + "…"
    out = (pos + " " + body).strip() if pos else body
    return out


def clean_meanings(translation, limit):
    """把 ECDICT 的 translation 拆成若干条短释义。"""
    text = (translation.replace("\\n", "|").replace("\\r", "|")
            .replace("\\t", " ")
            .replace("\r", "|").replace("\n", "|"))
    parts = []
    seen = set()
    for raw in text.split("|"):
        seg = raw.strip()
        if not seg:
            continue
        if seg.startswith(NOISE_PREFIX):
            continue
        seg = re.sub(r"^\[[^\]]{1,6}\]\s*", "", seg)     # 去掉 [医] [化] 之类
        seg = re.sub(r"\s+", " ", seg).strip(" ；;，,。")
        if re.search(r"[\u4e00-\u9fff]", seg):
            seg = re.sub(r"\s*[,，]\s*", "；", seg)
        if not seg or seg in seen:
            continue
        if len(seg) > MAX_MEANING_LEN:
            seg = seg[:MAX_MEANING_LEN].rstrip("；;，, ") + "…"
        seen.add(seg)
        parts.append(seg)
        if len(parts) >= limit:
            break
    return parts


# ---------------------------------------------------------------- 大小写变体
# Rime 的码表查询是大小写敏感的（Dictionary::LookupWords -> prism->GetValue 精确匹配），
# 词库里只有 hello 时打 Hello 一条候选都没有。这里给每个小写词复制一份「首字母大写」
# 变体（外加短词的全大写变体），行结构和原词完全一样：单词行 + 跟随其后的释义行。
#
# 代价只在词库体积和部署时间上，运行时零成本（prism 精确查表，多几万条不影响按键）。
CASE_TITLE_RE = re.compile(r"^[a-z][A-Za-z'\-]*$")


def case_variants(entries, seen_codes, caps_max_len=4):
    """返回新增条目 [(text, code, weight)]。

    entries: [(text, code, weight)]；同 code 的条目里，text == code 的那条算单词行，
    其余算释义行（会被一起复制到新 code 下）。
    """
    groups = {}
    for text, code, weight in entries:
        groups.setdefault(code, []).append((text, weight))

    extra = []
    for code in list(groups):
        items = groups[code]
        words = [(t, w) for t, w in items if t == code]
        if not words:
            continue
        word, w0 = words[0]
        if not CASE_TITLE_RE.match(word):
            continue

        variants = [word[0].upper() + word[1:]]
        # 短词（API / PDF / OK）顺手给全大写：长单词的全大写没人打，不必占体积
        if caps_max_len and 2 <= len(word) <= caps_max_len and word.isalpha():
            variants.append(word.upper())

        for v in variants:
            if v == word or v in seen_codes:
                continue
            seen_codes.add(v)
            extra.append((v, v, w0))
            for text, weight in items:
                if text != word:
                    extra.append((text, v, weight))
    return extra


def post_process_case(paths):
    """给已经生成好的词库补变体（不需要 ecdict.csv）。重复跑是幂等的。"""
    for path in paths:
        with open(path, encoding="utf-8") as f:
            raw = f.read().splitlines()
        try:
            end = next(i for i, line in enumerate(raw) if line.strip() == "...")
        except StopIteration:
            print(f"{path}: 找不到 yaml 结束标记，跳过", file=sys.stderr)
            continue
        entries = []
        for line in raw[end + 1:]:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            weight = int(parts[2]) if len(parts) > 2 and parts[2].strip().isdigit() else 0
            entries.append((parts[0], parts[1], weight))
        seen = {code for _, code, _ in entries}
        extra = case_variants(entries, seen)
        if not extra:
            print(f"{path}: 已有变体，未改动", file=sys.stderr)
            continue
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            for text, code, weight in extra:
                f.write(f"{text}\t{code}\t{weight}\n")
        print(f"{path}: +{len(extra)} 行（{len(extra) // 2} 个变体，{len(entries)} 条原有）",
              file=sys.stderr)


def compact(paths, prune_weak_variants=True):
    """整理已生成的词库（不需要 csv，幂等）：

      1. 每个编码只留**第一条**释义行（filter 只显示第一条，剩下的纯占体积）
      2. 释义行加 MEANING_MARK，filter 就不用猜"这行是词还是释义"
      3. 剪掉「变形的大写变体」（Titrated 这种，权重 5）：句子开头不会用它
    """
    for path in paths:
        with open(path, encoding="utf-8") as f:
            raw = f.read().splitlines()
        try:
            end = next(i for i, line in enumerate(raw) if line.strip() == "...")
        except StopIteration:
            print(f"{path}: 找不到 yaml 结束标记，跳过", file=sys.stderr)
            continue

        groups = {}                      # code -> [(text, weight)]，保持文件顺序
        for line in raw[end + 1:]:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            weight = int(parts[2]) if len(parts) > 2 and parts[2].strip().isdigit() else 0
            groups.setdefault(parts[1], []).append((parts[0], weight))

        out, dropped_meaning, dropped_cap = [], 0, 0
        for code, items in groups.items():
            words = [(t, w) for t, w in items if w > 0 or t == code]
            meanings = [(t, w) for t, w in items if w <= 0 and t != code]
            if not meanings and not words:
                continue
            # 变形的大写变体（Titrated 这种，权重 5）：句子开头不会用到，剪掉省体积
            if prune_weak_variants and words and code[:1].isupper() and max(w for _, w in words) < 10:
                dropped_cap += len(words) + len(meanings)
                continue
            seen_word = set()
            for text, weight in words:
                if text in seen_word:
                    continue
                seen_word.add(text)
                out.append((text, code, weight))
            if meanings:
                text = meanings[0][0]
                if not text.startswith(MEANING_MARK):
                    text = MEANING_MARK + text
                out.append((text, code, meanings[0][1]))
                dropped_meaning += len(meanings) - 1
            elif words:
                dropped_meaning += 0

        new_body = ["\t".join([t, c, str(w)]) for t, c, w in out]
        old_body = [l for l in raw[end + 1:] if l.strip() and not l.startswith("#")]
        if new_body == old_body:
            print(f"{path}: 已经是紧凑格式，未改动", file=sys.stderr)
            continue
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(raw[:end + 1]) + "\n")
            f.write("\n".join(new_body) + "\n")
        print(f"{path}: {len(old_body)} -> {len(new_body)} 行"
              f"（删多余释义 {dropped_meaning} 行，剪掉弱变体 {dropped_cap} 行）",
              file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", help="ECDICT 的 ecdict.csv（--case-variants 模式下不需要）")
    ap.add_argument("--out", help="输出 ecdict.dict.yaml")
    ap.add_argument("--case-variants", nargs="+", metavar="DICT",
                    help="只给已有的词库补首字母大写变体（不需要 csv），可给多个文件")
    ap.add_argument("--no-case-variants", action="store_true",
                    help="生成时不加大小写变体（词库体积约减半）")
    ap.add_argument("--compact", nargs="+", metavar="DICT",
                    help="整理已有词库：每码只留一条释义 + 加释义标记 + 剪掉弱变体（不需要 csv，幂等）")
    ap.add_argument("--limit", type=int, default=40000, help="基库收录多少个词（默认 40000）")
    ap.add_argument("--chem-out", help="另外生成化学词库（如 chem_ecdict.dict.yaml）")
    ap.add_argument("--chem-only-tag", default="[化]", help="化学词条的标记")
    ap.add_argument("--no-inflections", action="store_true", help="不生成时态/复数等变形")
    ap.add_argument("--max-meanings", type=int, default=3, help="每词最多几条释义")
    ap.add_argument("--dict-name", default="ecdict")
    args = ap.parse_args()

    if args.case_variants:
        post_process_case(args.case_variants)
        return
    if args.compact:
        compact(args.compact)
        return
    if not args.csv or not args.out:
        ap.error("生成词库需要 --csv 和 --out（或用 --case-variants 给已有词库补变体）")

    extra = {w for w in EXTRA_WORDS if WORD_RE.match(w)}
    cands, forced = [], []
    with open(args.csv, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            word = (row.get("word") or "").strip()
            if not WORD_RE.match(word):
                continue
            if not (row.get("translation") or "").strip():
                continue
            item = (parse_rank(row), len(word), word, row["translation"])
            if word in extra:
                forced.append((0, len(word), word, row["translation"]))
                extra.discard(word)
            cands.append(item)

    # 化学词库：ECDICT 里带 [化] 标记的单字词条（另外再并一批手工补充的）
    chem_words = {}
    if args.chem_out:
        with open(args.csv, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                word = (row.get("word") or "").strip()
                tr = row.get("translation") or ""
                if args.chem_only_tag not in tr:
                    continue
                if not WORD_RE.match(word) or len(word) < 3:
                    continue
                meanings = clean_meanings(tr.replace(args.chem_only_tag, ""), args.max_meanings)
                if not meanings:
                    continue
                short = brief(meanings, SHORT_MEANING_LEN)
                chem_words.setdefault(word, [short] + [m for m in meanings if m != short][:1])

    cands.sort(key=lambda x: (x[0], x[1], x[2]))
    picked = forced + cands[: args.limit]

    # 时态/复数/比较级等变形：ECDICT 的 exchange 列形如 "p:paid/d:paid/i:paying/3:pays"
    #   正向：收录的词 → 它的各变形
    #   反向：某词条的 0:lemma 指向收录的词（ran → run、bigger → big）
    inflections = {}
    if not args.no_inflections:
        keepers = {row[2] for row in picked} | set(chem_words)
        with open(args.csv, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                word = (row.get("word") or "").strip()
                ex = row.get("exchange") or ""
                if word in keepers:
                    for part in ex.split("/"):
                        kind, _, form = part.partition(":")
                        if kind in ("p", "d", "i", "3", "r", "t", "s") and WORD_RE.match(form):
                            inflections.setdefault(form, word)
                for part in ex.split("/"):
                    kind, _, lemma = part.partition(":")
                    if kind == "0" and lemma in keepers and WORD_RE.match(word) and word != lemma:
                        inflections.setdefault(word, lemma)

    lines = OrderedDict()      # 词 -> [释义...]
    for _, _, word, tr in picked:
        if word in lines:
            continue
        meanings = clean_meanings(tr, args.max_meanings)
        if not meanings:
            continue
        short = brief(meanings, SHORT_MEANING_LEN)
        keep = []
        s_body = split_pos(short)[1].replace("…", "")
        for m in meanings:
            m_body = split_pos(m)[1].replace("…", "")
            if not m_body or m_body == s_body:
                continue
            # 短的只是长版的前缀 / 长的只是短版的子集，都不重复列
            if s_body and (m_body.startswith(s_body) or s_body.startswith(m_body)):
                continue
            keep.append(m)
        lines[word] = [short] + keep[:FULL_LINES]

    with open(args.out, "w", encoding="utf-8", newline="\n") as out:
        out.write("# Rime dictionary\n")
        out.write("# encoding: utf-8\n")
        out.write("#v%d\n" % int(time.time()))
        out.write("#\n")
        out.write("# 由 scripts/ecdict2dict.py 从 ECDICT 生成，请勿手改。\n")
        out.write("# 数据源: https://github.com/skywind3000/ECDICT\n")
        out.write("#\n")
        out.write("---\n")
        out.write(f"name: {args.dict_name}\n")
        out.write('version: "0.1"\n')
        out.write("sort: by_weight\n")
        out.write("use_preset_vocabulary: false\n")
        out.write("...\n\n")
        for word, meanings in lines.items():
            out.write(f"{word}\t{word}\t10\n")
            for m in meanings:
                if m == word:
                    continue
                out.write(f"{MEANING_MARK}{m}\t{word}\t0\n")
        written = set(lines)
        for form in sorted(inflections):
            base = inflections[form]
            if form in written or base not in lines:
                continue
            hint = "%s（%s 的变形）" % (lines[base][0], base)
            out.write(f"{form}\t{form}\t5\n")
            out.write(f"{MEANING_MARK}{hint}\t{form}\t0\n")

    if args.chem_out:
        with open(args.chem_out, "w", encoding="utf-8", newline="\n") as out:
            out.write("# Rime dictionary\n# encoding: utf-8\n#v%d\n" % int(time.time()))
            out.write("# 化学词库（基础词库，由 scripts/ecdict2dict.py 从 ECDICT 的 [化] 词条生成）\n")
            out.write("# 通过 ecdict.dict.yaml 的 import_tables 合并进主词库\n")
            out.write("---\n")
            out.write("name: %s\n" % os.path.splitext(os.path.basename(args.chem_out))[0])
            out.write('version: "0.1"\n')
            out.write("sort: by_weight\n...\n\n")
            for word in sorted(chem_words):
                if word in lines:       # 主库已经有的就不重复（避免重复候选）
                    continue
                out.write(f"{word}\t{word}\t10\n")
                for m in chem_words[word]:
                    if m and m != word:
                        out.write(f"{MEANING_MARK}{m}\t{word}\t0\n")
            for form in sorted(inflections):
                base = inflections[form]
                if form in chem_words or base not in chem_words or form in lines:
                    continue
                hint = "%s（%s 的变形）" % (chem_words[base][0], base)
                out.write(f"{form}\t{form}\t5\n")
                out.write(f"{MEANING_MARK}{hint}\t{form}\t0\n")
        print(f"chem words={len(chem_words)} -> {args.chem_out}", file=sys.stderr)

    # 大小写变体 + 紧凑化：直接复用后处理（同一份实现，重复跑幂等）
    outs = [args.out] + ([args.chem_out] if args.chem_out else [])
    if not args.no_case_variants:
        post_process_case(outs)
    compact(outs)

    total = 1 + sum(1 for w, ms in lines.items() for m in ms if m != w)
    lens = [len(ms[0]) for ms in lines.values() if ms]
    if lens:
        lens.sort()
        print(f"短释义长度：中位 {lens[len(lens)//2]} 字，90% ≤ {lens[int(len(lens)*0.9)]} 字，最长 {lens[-1]}",
              file=sys.stderr)
    print(f"words={len(lines)} entries={total + len(lines)} -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
