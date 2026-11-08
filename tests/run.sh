#!/usr/bin/env bash
# 跑全部 Lua 回归测试（不需要输入法在运行）
#
#   bash tests/run.sh            # 全部
#   bash tests/run.sh en_assoc   # 只跑某一个（名字模糊匹配）
#
# 依赖：lua5.4（或 lua5.3+，需要 utf8 库）
#   Windows  WSL / Git Bash 里跑；或 choco install lua
#   macOS    brew install lua
#   Linux    apt install lua5.4
set -u

cd "$(dirname "$0")/.." || exit 1

LUA=""
for c in lua5.4 lua5.3 lua; do
  if command -v "$c" >/dev/null 2>&1; then LUA="$c"; break; fi
done
if [ -z "$LUA" ]; then
  echo "找不到 lua（试过 lua5.4 / lua5.3 / lua）" >&2
  exit 2
fi
# 用户自己的 lua 装在别处时：LUA=/tmp/lua54/usr/bin/lua5.4 bash tests/run.sh
LUA="${LUA_OVERRIDE:-$LUA}"

filter="${1:-}"
fail=0
for t in tests/test_*.lua; do
  name=$(basename "$t" .lua)
  case "$name" in
    *"$filter"*) ;;
    *) continue ;;
  esac
  printf '%-32s ' "$name"
  out=$("$LUA" "$t" 2>&1)
  if [ $? -eq 0 ]; then
    echo "OK"
  else
    echo "FAIL"
    echo "$out" | grep -E '\[FAIL\]|FATAL' | sed 's/^/    /'
    fail=1
  fi
done
[ $fail -eq 0 ] && echo "--- 全部通过" || echo "--- 有失败"
exit $fail
