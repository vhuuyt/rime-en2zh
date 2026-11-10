-- test_mode_switch.lua
-- 用法：在 Rime 用户目录下执行  lua tests/test_mode_switch.lua
-- 验证「Shift 单击切换方案」：中文 → english → 切回中文；
-- 按住 Shift 打字（Shift+a）不触发切换。

local script = arg and arg[0] or "test_mode_switch.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

package.path = dir .. "/lua/?.lua;" .. package.path

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/mode_switch.lua")
  if not f then dir = dir .. "/.." else f:close() end
end

local ok, M = pcall(dofile, dir .. "/lua/mode_switch.lua")
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 lua/mode_switch.lua 失败: " .. tostring(M))
  os.exit(1)
end

-- ---- mock ----
-- 注意：Weasel 里 Shift 键事件的 repr 带修饰键前缀（"Shift+Shift_L"），
-- 因为按下 Shift 时键盘状态里 Shift 已经是按下状态。
local function mk_key(repr, release, keycode)
  return {
    repr = function() return repr end,
    release = function() return release and true or false end,
    keycode = keycode or 0x61,      -- 默认当成普通字母 'a' 
  }
end

local function mk_env(schema_id, shift_right, shift_left)
  local props = {}
  local applied = {}
  local options = {}
  local env = {
    engine = {
      schema = {
        schema_id = schema_id,
        config = {
          get_string = function(_, key)
            if key == "en_ai/shift_right" then return shift_right end
            if key == "en_ai/shift_left" then return shift_left end
            return nil
          end,
        },
      },
      context = {
        set_property = function(_, k, v) props[k] = v end,
        get_property = function(_, k) return props[k] or "" end,
        -- 配成 ascii 的那一侧走 ascii_mode 开关
        set_option = function(_, k, v) options[k] = v and true or false end,
        get_option = function(_, k) return options[k] and true or false end,
        is_composing = function() return false end,
        clear = function() end,
      },
      apply_schema = function(_, schema) applied[#applied + 1] = schema.schema_id end,
    },
    applied = applied,
    options = options,
  }
  M.init(env)
  return env
end

-- 全局的 Schema 构造器（librime-lua 提供）
local schema_calls = {}
function Schema(id)
  schema_calls[#schema_calls + 1] = id
  return { schema_id = id }
end

local failed = 0
local function check(name, cond, detail)
  if cond then
    print(string.format("  [PASS] %s", name))
  else
    failed = failed + 1
    print(string.format("  [FAIL] %s%s", name, detail and (" -> " .. detail) or ""))
  end
end

print("== mode_switch 测试 ==")

-- 1. 中文方案：Shift 按下 → 放行（不拦截，否则打不出大写）
local env = mk_env("double_pinyin_mspy")
local r = env.engine and M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env)
check("Shift 按下不拦截", r == 2, "r=" .. tostring(r))
check("Shift 按下不切方案", #env.applied == 0, "n=" .. #env.applied)

-- 2. Shift 松开（期间没按别的键）→ 切到 english
r = M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env)
check("Shift 松开切方案", r == 1, "r=" .. tostring(r))
check("切到 english", env.applied[1] == "english", tostring(env.applied[1]))
check("记下了来源方案", env.engine.context:get_property("last_cn_schema") == "double_pinyin_mspy")

-- 3. english 方案：Shift 松开 → 切回刚才的中文方案
local env2 = mk_env("english")
env2.engine.context.set_property(env2.engine.context, "last_cn_schema", "luna_pinyin")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env2)
r = M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env2)
check("english 里 Shift 松开切回中文", r == 1, "r=" .. tostring(r))
check("切回 luna_pinyin", env2.applied[1] == "luna_pinyin", tostring(env2.applied[1]))

-- 4. english 方案里没有记录来源 → 用默认的双拼
local env3 = mk_env("english")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env3)
M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env3)
check("没有记录时用默认方案", env3.applied[1] == "double_pinyin_mspy", tostring(env3.applied[1]))

-- 5. 按住 Shift 打字 → 不切换
local env4 = mk_env("double_pinyin_mspy")
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env4)          -- 按下
r = M.func(mk_key("a"), env4)              -- 按住 shift 打了字母
check("按住 Shift 打字不拦截", r == 2, "r=" .. tostring(r))
r = M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env4)  -- 松开
check("按住 Shift 后松开不切换", #env4.applied == 0, "n=" .. #env4.applied)
check("按住 Shift 后松开放行", r == 2, "r=" .. tostring(r))

-- 6. 默认：左 Shift 单击 = 中文 ⇄ 西文（只切 ascii_mode，不换方案）
local env5 = mk_env("luna_pinyin")
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env5)
local r5 = M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env5)
check("左 Shift 单击被吃掉", r5 == 1, "r=" .. tostring(r5))
check("左 Shift 打开西文（ascii_mode）", env5.options["ascii_mode"] == true,
      tostring(env5.options["ascii_mode"]))
check("左 Shift 不切方案", #env5.applied == 0, "n=" .. #env5.applied)
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env5)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env5)
check("再按一次回到中文", env5.options["ascii_mode"] == false,
      tostring(env5.options["ascii_mode"]))

-- 6b. 默认：右 Shift 单击 = 中文 ⇄ 英文模式（切方案）
local env6 = mk_env("double_pinyin_mspy")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env6)
local r6 = M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env6)
check("右 Shift 切到英文模式", r6 == 1 and env6.applied[1] == "english",
      "r=" .. tostring(r6) .. " schema=" .. tostring(env6.applied[1]))
check("右 Shift 不碰 ascii_mode", env6.options["ascii_mode"] == nil,
      tostring(env6.options["ascii_mode"]))

-- 6c. 想换回来：shift_left: schema / shift_right: ascii
local env6c = mk_env("double_pinyin_mspy", "ascii", "schema")
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env6c)
local r6c = M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env6c)
check("shift_left=schema 时左 Shift 切方案", r6c == 1 and env6c.applied[1] == "english",
      "r=" .. tostring(r6c))
local env6d = mk_env("luna_pinyin", "ascii", "schema")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env6d)
M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env6d)
check("shift_right=ascii 时右 Shift 切西文", env6d.options["ascii_mode"] == true
      and #env6d.applied == 0, tostring(env6d.options["ascii_mode"]))

-- 7. 连续两次单击：切换 → 切回
local env6 = mk_env("double_pinyin_mspy")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env6)
M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env6)     -- → english
local env7 = mk_env("english")
env7.engine.context.set_property(env7.engine.context, "last_cn_schema", "double_pinyin_mspy")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env7)
M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env7)     -- → 回到中文
check("切过去再切回来", env7.applied[1] == "double_pinyin_mspy", tostring(env7.applied[1]))

-- 8. 其它按键完全不干预
local env8 = mk_env("double_pinyin_mspy")
r = M.func(mk_key("a"), env8)
check("普通按键放行", r == 2 and #env8.applied == 0)

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
