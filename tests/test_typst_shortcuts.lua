-- test_typst_shortcuts.lua
-- 用法：在 Rime 用户目录下执行  lua test_typst_shortcuts.lua
-- 直接加载 lua/typst_shortcuts.lua，用 mock 的 key/env 验证快捷键行为。

local script = arg and arg[0] or "test_typst_shortcuts.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/typst_shortcuts.lua")
  if not f then dir = dir .. "/.." else f:close() end
end

local target = dir .. "/lua/typst_shortcuts.lua"

local ok, processor = pcall(dofile, target)
if not ok then
  print("[FATAL] 加载 " .. target .. " 失败: " .. tostring(processor))
  os.exit(1)
end

local func = processor
if type(processor) == "table" then
  func = processor.func
end
if type(func) ~= "function" then
  print("[FATAL] " .. target .. " 未返回处理函数")
  os.exit(1)
end

-- ---- mock 环境 ----
local committed = {}
local composing = false

local env = {
  engine = {
    commit_text = function(_, text) committed[#committed + 1] = text end,
    context = { is_composing = function() return composing end },
  },
}

local function make_key(repr)
  return { repr = function() return repr end }
end

local function reset(c)
  committed = {}
  composing = c and true or false
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

local function expect(name, repr, want, comp)
  reset(comp)
  local r = func(make_key(repr), env)
  if want == nil then
    check(name, #committed == 0 and r == 2,
          "count=" .. #committed .. " r=" .. tostring(r))
  else
    check(name, committed[1] == want and r == 1 and #committed == 1,
          "got=" .. tostring(committed[1]) .. " r=" .. tostring(r)
          .. " count=" .. #committed)
  end
end

print("== typst_shortcuts 测试 (" .. target .. ") ==")

expect("Ctrl+. 上屏 #super[", "Control+period", "#super[")
expect("Ctrl+Shift+, 上屏 #sub[ (Weasel: less)", "Shift+Control+less", "#sub[")
expect("Ctrl+Shift+, 上屏 #sub[ (Squirrel: comma)", "Shift+Control+comma", "#sub[")
expect("Ctrl+Shift+G 上屏 figure 模板", "Shift+Control+G",
       '#figure(image(""), caption: [])')
expect("普通按键 a 返回 2", "a", nil)
expect("Ctrl+, 不触发", "Control+comma", nil)
expect("Control+Shift+comma 顺序不对", "Control+Shift+comma", nil)
expect("Control+Shift+G 顺序不对", "Control+Shift+G", nil)
expect("Shift+Control+g 小写不触发", "Shift+Control+g", nil)
expect("Shift+Control+greater 不触发", "Shift+Control+greater", nil)
expect("拼写中 Ctrl+. 不插入", "Control+period", nil, true)
expect("拼写中 Ctrl+Shift+G 不插入", "Shift+Control+G", nil, true)

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
