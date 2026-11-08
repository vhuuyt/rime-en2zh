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

local function mk_env(schema_id, opts)
  local props = {}
  local applied = {}
  local options = {}
  for k, v in pairs(opts or {}) do options[k] = v end
  local env = {
    engine = {
      schema = { schema_id = schema_id },
      context = {
        set_property = function(_, k, v) props[k] = v end,
        get_property = function(_, k) return props[k] or "" end,
        set_option = function(_, k, v) options[k] = v and true or false end,
        get_option = function(_, k) return options[k] and true or false end,
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
local r = env.engine and M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env)
check("Shift 按下不拦截", r == 2, "r=" .. tostring(r))
check("Shift 按下不切方案", #env.applied == 0, "n=" .. #env.applied)

-- 2. Shift 松开（期间没按别的键）→ 切到 english
r = M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env)
check("Shift 松开切方案", r == 1, "r=" .. tostring(r))
check("切到 english", env.applied[1] == "english", tostring(env.applied[1]))
check("记下了来源方案", env.engine.context:get_property("last_cn_schema") == "double_pinyin_mspy")

-- 3. english 方案：Shift 松开 → 切回刚才的中文方案
local env2 = mk_env("english")
env2.engine.context.set_property(env2.engine.context, "last_cn_schema", "luna_pinyin")
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env2)
r = M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env2)
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

-- 6. 右 Shift 一样
local env5 = mk_env("luna_pinyin")
M.func(mk_key("Shift+Shift_R", false, 0xFFE2), env5)
M.func(mk_key("Shift+Shift_R", true, 0xFFE2), env5)
check("右 Shift 也能切", env5.applied[1] == "english", tostring(env5.applied[1]))

-- 7. 连续两次单击：切换 → 切回
local env6 = mk_env("double_pinyin_mspy")
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env6)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env6)     -- → english
local env7 = mk_env("english")
env7.engine.context.set_property(env7.engine.context, "last_cn_schema", "double_pinyin_mspy")
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), env7)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), env7)     -- → 回到中文
check("切过去再切回来", env7.applied[1] == "double_pinyin_mspy", tostring(env7.applied[1]))

-- 8. 标点：切到英文 → ASCII 标点；切回中文 → 中文标点
local envp = mk_env("double_pinyin_mspy")          -- 中文侧本来是中文标点
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), envp)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), envp)
check("切到 english 时 ascii_punct 打开", envp.options["ascii_punct"] == true,
      tostring(envp.options["ascii_punct"]))

local envp2 = mk_env("english")
envp2.engine.context.set_property(envp2.engine.context, "last_cn_schema", "double_pinyin_mspy")
envp2.engine.context.set_property(envp2.engine.context, "last_cn_ascii_punct", "0")
envp2.options["ascii_punct"] = true                 -- 英文侧留下的状态
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), envp2)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), envp2)
check("切回中文后 ascii_punct 关掉（逗号句号恢复中文）", envp2.options["ascii_punct"] == false,
      tostring(envp2.options["ascii_punct"]))

-- 8b. 中文侧本来就开着 ascii_punct（Ctrl+. 切过的）→ 切一圈回来仍然开着
local envp3 = mk_env("double_pinyin_mspy", { ascii_punct = true })
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), envp3)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), envp3)
check("记住中文侧的 ascii_punct", envp3.engine.context:get_property("last_cn_ascii_punct") == "1",
      envp3.engine.context:get_property("last_cn_ascii_punct"))
local envp4 = mk_env("english")
envp4.engine.context.set_property(envp4.engine.context, "last_cn_schema", "double_pinyin_mspy")
envp4.engine.context.set_property(envp4.engine.context, "last_cn_ascii_punct", "1")
envp4.options["ascii_punct"] = true
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), envp4)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), envp4)
check("原本开着 ascii_punct 的保持开着", envp4.options["ascii_punct"] == true,
      tostring(envp4.options["ascii_punct"]))

-- 8c. 没有记录（旧状态）→ 回到中文标点
local envp5 = mk_env("english")
envp5.options["ascii_punct"] = true
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), envp5)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), envp5)
check("没有记录时回到中文标点", envp5.options["ascii_punct"] == false,
      tostring(envp5.options["ascii_punct"]))

-- 8d. 切方案时都把 ascii_mode 清掉（中文要打中文，英文要打字母）
local envp6 = mk_env("double_pinyin_mspy", { ascii_mode = true })
M.func(mk_key("Shift+Shift_L", false, 0xFFE1), envp6)
M.func(mk_key("Shift+Shift_L", true, 0xFFE1), envp6)
check("切到英文时 ascii_mode 关掉", envp6.options["ascii_mode"] == false,
      tostring(envp6.options["ascii_mode"]))

-- 9. 其它按键完全不干预
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
