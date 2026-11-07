-- lua/select_character.lua   【中文】processor
--
-- 以词定字：候选有词时，按键取词首 / 词末单字上屏。
--   默认 [ 取首字、] 取末字（可在 schema 里改：key_binder/select_first_character）
--
-- 挂载：
--   engine/processors:
--     - lua_processor@*select_character   # 必须早于 punctuator 和 key_binder
--   key_binder/select_first_character: bracketleft
--   key_binder/select_last_character: bracketright
--
-- 三端键名一致：macOS(Squirrel) 按物理键位映射 kVK_ANSI_LeftBracket → bracketleft；
-- Windows(Weasel) 走 ToUnicodeEx → '[' = bracketleft；Linux(ibus) 走 X11 keysym 同名。

local M = {}

function M.init(env)
  local cfg = env.engine.schema.config
  env.first_key = cfg:get_string("key_binder/select_first_character")
  env.last_key = cfg:get_string("key_binder/select_last_character")
end

local function first_char(s)
  local o = utf8.offset(s, 2)
  return o and s:sub(1, o - 1) or s
end

local function last_char(s)
  local o = utf8.offset(s, -1)
  return o and s:sub(o) or s
end

function M.func(key, env)
  if key:release() then
    return 2
  end
  local repr = key:repr()
  local pick
  if repr == env.first_key then
    pick = first_char
  elseif repr == env.last_key then
    pick = last_char
  else
    return 2
  end

  local ctx = env.engine.context
  if not (ctx:is_composing() or ctx:has_menu()) then
    return 2
  end

  -- 当前选中候选；没有候选（纯输入还没上屏）就把输入本身当候选
  local cand = ctx:get_selected_candidate()
  local text = cand and cand.text or ctx.input
  if not text or text == "" then
    return 2
  end

  local ch = pick(text)

  -- commit_text = 已确认片段 + 当前候选 + 尚未处理的输入，
  -- 把其中的候选词替换成单字再上屏，剩下的输入还回输入法。
  local full = ctx:get_commit_text() or ""
  local s, e = full:find(text, 1, true)
  if not s then
    env.engine:commit_text(ch)
    ctx:clear()
    return 1
  end

  local head = full:sub(1, s - 1)
  local tail = full:sub(e + 1)

  env.engine:commit_text(head .. ch)
  ctx:clear()
  if tail ~= "" then
    ctx:push_input(tail)
  end
  return 1
end

return M
