-- lua/typst_shortcuts.lua    【三方案通用】processor
--
-- Typst 快捷片段（snippet）：
--   Ctrl+.        → #super[
--   Ctrl+Shift+,  → #sub[
--   Ctrl+Shift+G  → #figure(image(""), caption: [])
--
-- 右方括号自己敲（custom.yaml 里已把 "]" 改成 ASCII）。
--
-- ★ 为什么下标写 "Shift+Control+less" 而不是 "Shift+Control+comma"？
--   小狼毫把 Win32 按键翻成 librime keysym 时，VK_OEM_COMMA 这类标点在
--   TranslateKeycode() 里没有分支，会退回 ToUnicodeEx() 取字符，而取字符时
--   Shift 状态是保留的（只清 Ctrl/Alt）：
--       Ctrl+.        → '.'(0x2E) → "period" → "Control+period"
--       Ctrl+Shift+,  → '<'(0x3C) → "less"   → "Shift+Control+less"
--   macOS 的 Squirrel 相反：先查物理键位表（kVK_ANSI_Comma → XK_comma），
--   所以是 "Shift+Control+comma"；Linux/ibus 走 X11 keysym，又是 less。
--   两个名字都留着，三端才一致。
--
-- ★ 字母键的大小写也要当心：Shift 按下时取到的是大写字母，
--   所以 Ctrl+Shift+G 的 repr 是 "Shift+Control+G"（大写 G），
--   而 Ctrl+G 是 "Control+g"（小写）。表里的键必须完全一致。
--
-- ★ 修饰键顺序由 librime key_table.cc 的 modifier_name[] 决定，固定为
--   Shift → Lock → Control → Alt → Super → Hyper → Meta → Release。

-- 正在拼写中文时（有 composition）不插入片段，避免把文本插到拼音中间
local SKIP_WHEN_COMPOSING = true

local snippets = {
  -- ---- 上下标 ----
  ["Control+period"] = "#super[",     -- Ctrl+.
  ["Shift+Control+less"] = "#sub[",   -- Ctrl+Shift+,（小狼毫实际键名）
  ["Shift+Control+comma"] = "#sub[",  -- Ctrl+Shift+,（其它前端）

  -- ---- Typst 模板 ----
  -- 一次上屏整段；IME 只能顺序上屏，光标会停在最后的 "])" 之后
  ["Shift+Control+G"] = '#figure(image(""), caption: [])',

  -- 想让光标落在 image("…") 的引号里？用分步版（取消下面两行注释）：
  --   Ctrl+Shift+I → 打出 #figure(image("        光标就在两个引号中间，先敲路径
  --   Ctrl+Shift+J → 打出 "), caption: [         再敲 caption，最后手动补 ])
  -- ["Shift+Control+I"] = '#figure(image("',
  -- ["Shift+Control+J"] = '"), caption: [',

  -- 可选：让 Ctrl+Shift+. 也能上标（Windows 上它的 repr 是 greater）
  -- ["Shift+Control+greater"] = "#super[",
}

local function processor(key, env)
  local text = snippets[key:repr()]
  if not text then
    return 2 -- kNoop：未处理，交给后面的处理器
  end

  local ctx = env.engine.context
  if SKIP_WHEN_COMPOSING and ctx and ctx:is_composing() then
    return 2
  end

  env.engine:commit_text(text) -- 上屏，应用程序里的光标紧跟其后
  return 1                     -- kAccepted：按键已被处理
end

return processor
