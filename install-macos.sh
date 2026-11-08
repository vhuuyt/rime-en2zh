#!/bin/bash
# install-macos.sh — 把本仓库装进 ~/Library/Rime（macOS / Squirrel）
#
# 用法：
#   git clone https://github.com/vhuuyt/rime-en2zh.git && cd rime-en2zh
#   bash install-macos.sh
#
# 做的事：
#   1. 把现有 ~/Library/Rime 备份到 ~/Library/Rime.bak-<时间>
#   2. 拷入：方案 / 补丁 / lua / scripts / tests / docs / dicts
#   3. 保留本机自己的：squirrel.custom.yaml、installation.yaml、user.yaml、
#      *.userdb、build/、ai_config.json（含 key）、dicts/ai_ecdict.dict.yaml（AI 补录的词）
#   4. 重新部署（Squirrel --reload）
#
# 注意：english.schema.yaml 和 lua/*.lua 必须一起换 —— 只换一边会出现
#      「方案引用了不存在/类型不符的 lua 组件」的部署错误。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RIME="${RIME_DIR:-$HOME/Library/Rime}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$RIME.bak-$STAMP"

echo "==> 源目录: $HERE"
echo "==> 目标:   $RIME"

[ -f "$HERE/english.schema.yaml" ] || { echo "!! 这里不像仓库根目录（没有 english.schema.yaml）"; exit 1; }

mkdir -p "$RIME"

echo "==> 备份现有配置到 $BACKUP"
cp -a "$RIME" "$BACKUP" 2>/dev/null || true

# dicts/ai_ecdict.dict.yaml 是各端自己攒的 AI 补录词，别被仓库版本覆盖
AI_DICT="$RIME/dicts/ai_ecdict.dict.yaml"
AI_KEEP=""
if [ -f "$AI_DICT" ]; then
  AI_KEEP="$(mktemp)"
  cp -a "$AI_DICT" "$AI_KEEP"
  echo "    记住本机 AI 词库（$(grep -c . "$AI_DICT") 行）"
fi

copy_one() {
  local item="$1"
  [ -e "$HERE/$item" ] || return 0
  rm -rf "${RIME:?}/$item"
  cp -a "$HERE/$item" "$RIME/$item"
  echo "    + $item"
}

echo "==> 安装配置"
for item in default.custom.yaml \
            double_pinyin_mspy.custom.yaml double_pinyin_mspy.schema.yaml \
            luna_pinyin.custom.yaml english.schema.yaml \
            vhuuyt.dict.yaml en.dict.yaml \
            README.md lua scripts tests docs dicts; do
  copy_one "$item"
done

if [ -n "$AI_KEEP" ]; then
  mkdir -p "$RIME/dicts"
  cp -a "$AI_KEEP" "$AI_DICT"
  rm -f "$AI_KEEP"
  echo "    = 还原本机 AI 词库"
fi

# 本机没有 squirrel.custom.yaml 时才装一份模板（有就保留你的）
if [ ! -f "$RIME/squirrel.custom.yaml" ] && [ -f "$HERE/squirrel.custom.yaml" ]; then
  cp -a "$HERE/squirrel.custom.yaml" "$RIME/squirrel.custom.yaml"
  echo "    + squirrel.custom.yaml（模板）"
else
  echo "    = 保留你现有的 squirrel.custom.yaml"
fi

chmod +x "$RIME/scripts/"*.py "$RIME/tests/run.sh" 2>/dev/null || true

echo "==> 自检：english.schema.yaml 里 en_space 必须在 processors"
if grep -q 'lua_processor@\*en_space' "$RIME/english.schema.yaml"; then
  echo "    ok（自动补空格走 processor）"
else
  echo "    !! 没找到 lua_processor@*en_space，检查 english.schema.yaml"
fi

echo "==> 重新部署"
SQUIRREL="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
if [ -x "$SQUIRREL" ]; then
  "$SQUIRREL" --reload || "$SQUIRREL" --deploy || true
  echo "    已触发 Squirrel 重载"
else
  echo "    ! 没找到 Squirrel，请手动在菜单里「重新部署」"
fi

cat <<'TIP'

==> 完成。接下来：

1) F4（或 Control+` / Control+Shift+E）确认方案里有：双拼 MSPY、英文模式
2) 英文模式：空格上单词（自动带尾随空格）、Ctrl+Enter 上屏释义、
   Ctrl+Delete 删 AI 补录词、Tab 滚动长释义
3) 想用大模型：
     python3 "$HOME/Library/Rime/scripts/ai_bridge.py" --once hello   # 先验 key/网络
     python3 "$HOME/Library/Rime/scripts/install_autostart.py"        # 开机自启
   然后把 key 填进 ~/Library/Rime/ai_config.json
4) 改完 lua 不用手动部署：桥会自动重启输入法（librime-lua 每个会话只加载一次模块）
5) 回滚：rm -rf ~/Library/Rime && mv ~/Library/Rime.bak-<时间> ~/Library/Rime

TIP
