-- lua/mode_switch.lua        【三方案通用】processor（必须放在 processors 第一位）
--
-- Shift 单击切换方案：
--   中文（双拼 / 朙月）→ english（带释义的英文查词）
--   english           → 切回刚才那个中文方案
--
-- 判定沿用 Rime 原生「单击 Shift 切西文」的手感：
--   按下 Shift 记一笔；这期间按了别的键 → 算「按住 Shift 打字」，不切换；
--   松开 Shift 时若期间没按过别的键 → 单击，切换方案。
--
-- 只在「松开」时吃掉按键，按下不拦截：
--   * Shift+字母 仍然正常打出大写
--   * ascii_composer 收不到 release，就不会再去切 ascii_mode
--
-- 切到英文时把当前方案 id 记在 context 属性里（属性跨方案切换保留），切回来时用。
--
-- 顺带修标点：Context 的 option 是会话级的，apply_schema 不会还原，
-- 英文方案的 ascii_punct=1 会滲到中文方案上（切回来逗号句号还是英文的）。
-- 所以切换时两边的 ascii_punct / ascii_mode 都显式设一遍。
--
-- 挂载：engine/processors 第一项 lua_processor@*mode_switch

local M = {}

local ENGLISH = "english"
local DEFAULT_CN = "double_pinyin_mspy"
local PROP = "last_cn_schema"
-- 切到英文前把中文侧的 ascii_punct 记下来，切回来时还原
local PROP_PUNCT = "last_cn_ascii_punct"

-- Context 的 option 是会话级的，apply_schema **不会**把它还原：
-- english 方案里 ascii_punct 是 1，切回中文后它还是 1 ——
-- 逗号句号就一直是英文的 , . 这就是「切回来标点不对」的原因。
-- 两边都显式设一遍。
local function set_options(ctx, ascii_punct, ascii_mode)
  pcall(function() ctx:set_option("ascii_punct", ascii_punct) end)
  pcall(function() ctx:set_option("ascii_mode", ascii_mode) end)
end

local function current_schema(env)
  local s = env.engine.schema
  return (s and s.schema_id) or ""
end

-- Shift 键的 repr 带修饰键前缀（Weasel 里按下 Shift 时键盘状态里 Shift 已按下，
-- 所以 repr 是 "Shift+Shift_L" 而不是 "Shift_L"），所以要按 keycode 判断。
local XK_SHIFT_L = 0xFFE1
local XK_SHIFT_R = 0xFFE2

local function is_shift_key(key, repr)
  local kc = key.keycode
  if kc == XK_SHIFT_L or kc == XK_SHIFT_R then
    return true
  end
  -- 兜底：按 repr 结尾判断
  return repr:match("Shift_L$") ~= nil or repr:match("Shift_R$") ~= nil
end

function M.init(env)
  env.shift_down = false
  env.typed = false
end

function M.func(key, env)
  local repr = key:repr()

  if is_shift_key(key, repr) then
    if key:release() then
      -- 松开：只有「按下之后没按过别的键」才算单击
      local solo = env.shift_down and not env.typed
      env.shift_down = false
      env.typed = false
      if not solo then
        return 2
      end

      local ctx = env.engine.context
      local cur = current_schema(env)
      if cur == ENGLISH then
        local back = ctx:get_property(PROP)
        if back == nil or back == "" or back == ENGLISH then
          back = DEFAULT_CN
        end
        -- 还原中文标点（原本就开着 ascii_punct 的保持开着）
        set_options(ctx, ctx:get_property(PROP_PUNCT) == "1", false)
        env.engine:apply_schema(Schema(back))
      else
        ctx:set_property(PROP, cur)
        -- 记住中文侧现在的标点状态，英文固定用 ASCII 标点
        local ok, punct = pcall(function() return ctx:get_option("ascii_punct") end)
        ctx:set_property(PROP_PUNCT, (ok and punct) and "1" or "0")
        set_options(ctx, true, false)
        env.engine:apply_schema(Schema(ENGLISH))
      end
      -- 注意：apply_schema 会重建 processor 链（当前这个也会被销毁），
      -- 所以这里必须立刻返回，不要再碰 env 里的东西。
      return 1        -- 吃掉这次松开，ascii_composer 就不会切 ascii_mode
    end
    -- 按下：只记录，不拦截（否则 Shift+字母 就打不出大写了）
    env.shift_down = true
    env.typed = false
    return 2
  end

  if env.shift_down then
    env.typed = true       -- 按住 Shift 期间按了别的键
  end
  return 2
end

return M
