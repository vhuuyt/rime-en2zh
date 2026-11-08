-- test_punct_switch.lua
-- 用法：在 Rime 用户目录下执行  lua tests/test_punct_switch.lua
--
-- 配置级回归测试：切方案时标点要跟着走，靠的是 schema 的 switches 里的 reset。
--
-- librime 的 ConcreteEngine::ApplySchema → InitializeOptions() →
-- Switches::FindOption()，对每个 option 判断 reset_value >= 0 就 set_option：
--
--     inline static int reset_value(ConfigItemRef& item) {
--       auto reset = item["reset"];
--       return reset.IsValue() ? reset.ToInt() : -1;     // 没写 reset = -1 = 不动
--     }
--     ...
--     if (option.reset_value >= 0)
--       context_->set_option(option.option_name, (option.reset_value != 0));
--
-- 所以：中文方案的 ascii_punct 必须写 reset: 0，否则英文方案留下的 1
-- 会一直滲过来（切回双拼后逗号句号还是 , .）。

local script = arg and arg[0] or "test_punct_switch.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

do
  local f = io.open(dir .. "/double_pinyin_mspy.schema.yaml")
  if not f then dir = dir .. "/.." else f:close() end
end

local function read(path)
  local f = io.open(dir .. "/" .. path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- 从 switches: 段里找出某个 option 的 reset 值；没写就返回 nil
local function reset_of(text, option)
  if not text then return nil end
  local in_switches, cur, reset = false, nil, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^switches:%s*$") then
      in_switches = true
    elseif in_switches and line:match("^%S") then
      break                                   -- 出了 switches 段
    elseif in_switches then
      local name = line:match("^%s*%-%s*name:%s*(%S+)")
      if name then
        if cur == option then return reset end
        cur, reset = name, nil
      else
        local v = line:match("^%s*reset:%s*(%-?%d+)")
        if v and cur then reset = tonumber(v) end
      end
    end
  end
  if cur == option then return reset end
  return nil
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

print("== punct_switch 配置测试 (" .. dir .. ") ==")

local cn = read("double_pinyin_mspy.schema.yaml")
local en = read("english.schema.yaml")
local luna = read("luna_pinyin.custom.yaml")

check("双拼 schema 存在", cn ~= nil)
check("english schema 存在", en ~= nil)

local cn_ap = reset_of(cn, "ascii_punct")
check("双拼 ascii_punct 有 reset: 0（切回来标点回中文）", cn_ap == 0, tostring(cn_ap))

local cn_am = reset_of(cn, "ascii_mode")
check("双拼 ascii_mode 有 reset: 0", cn_am == 0, tostring(cn_am))

local en_ap = reset_of(en, "ascii_punct")
check("english ascii_punct 有 reset: 1（英文用 ASCII 标点）", en_ap == 1, tostring(en_ap))

-- F4 选单里的开关：没写 states 的 switch 不会出现在菜单里
-- （switch_translator.cc: if (!has_state_label(option, 0)) return kContinue;）
local function has_states(text, option)
  if not text then return false end
  local in_switches, cur, hit = false, nil, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^switches:%s*$") then
      in_switches = true
    elseif in_switches and line:match("^%S") then
      break
    elseif in_switches then
      local name = line:match("^%s*%-%s*name:%s*(%S+)")
      if name then
        if cur == option and hit then return true end
        cur, hit = name, false
      elseif cur == option and line:match("^%s*states:") then
        hit = true
      end
    end
  end
  return cur == option and hit
end

check("english 声明了 no_auto_space 开关（F4 可见）", has_states(en, "no_auto_space"))
check("no_auto_space 故意不写 reset（写了每次切方案都会重置回去）",
      reset_of(en, "no_auto_space") == nil, tostring(reset_of(en, "no_auto_space")))

local def = read("default.custom.yaml")
check("default.custom.yaml 把 no_auto_space 加进 switcher/save_options",
      def ~= nil and def:find("save_options") ~= nil and def:find("no_auto_space") ~= nil)
check("english ai_translate 开关仍在菜单", has_states(en, "ai_translate"))
check("english ascii_punct 不显示在菜单（无 states）", not has_states(en, "ascii_punct"))

-- 朙月拼音的 switches 在基础方案里（随发行版），只能用 @索引 打补丁
local has_luna_patch = luna ~= nil and luna:find("switches/@3/reset:%s*0") ~= nil
check("朙月 custom 补了 switches/@3/reset: 0", has_luna_patch)

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
