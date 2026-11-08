-- test_en_assoc.lua
-- 用法：在 Rime 用户目录下执行  lua tests/test_en_assoc.lua
-- 验证「联想模式」filter：释义进 comment、释义行丢掉、大写回退、
-- 补 AI 词候选、完整释义记到 en_state。

local script = arg and arg[0] or "test_en_assoc.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

package.path = dir .. "/lua/?.lua;" .. package.path   -- 让 require 找得到

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/en_assoc.lua")
  if not f then dir = dir .. "/.." else f:close() end
  package.path = dir .. "/lua/?.lua;" .. package.path
end

local state = require("en_state")

local ok, M = pcall(dofile, dir .. "/lua/en_assoc.lua")
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 lua/en_assoc.lua 失败: " .. tostring(M))
  os.exit(1)
end

-- ---- 造词库文件 ----
local tmpdir = os.tmpname()
os.remove(tmpdir)
os.execute('mkdir -p "' .. tmpdir .. '"')

local aidict = tmpdir .. "/ai_ecdict.dict.yaml"

local ver = 0
local function write(path, body)
  ver = ver + 1
  local f = io.open(path, "w")
  f:write("#v", ver, "\n", body)     -- 版本号变了 → 共享模块会重读
  f:close()
end

-- AI 词库（filter 只读这一份，很小）
write(aidict, table.concat({
  "typst\ttypst\t10",
  "n. 排版系统\ttypst\t0",
  "Typst\tTypst\t10",
  "n. 排版系统\tTypst\t0",
  "phrasal\tphrasal\t0",
  "", }, "\n"))

-- ---- mock ----
-- 质量是识别"单词候选/释义候选"的关键：
-- 词库单词行权重 10 → 质量≈22026；释义行权重 0 → 质量≈1
local function mk_word(text, comment)
  return { text = text, comment = comment, quality = 22026 }
end

local function mk_meaning(text)
  return { text = text, comment = nil, quality = 1 }
end

local function mk_input(cands)
  return {
    iter = function()
      local i = 0
      return function()
        i = i + 1
        return cands[i]
      end
    end,
  }
end

local yielded = {}
function Candidate(typ, start, end_, text, comment)
  return { type = typ, start = start, _end = end_, text = text, comment = comment, quality = 0 }
end
function yield(c) yielded[#yielded + 1] = c end

local env = {
  engine = {
    context = { get_option = function() return true end, input = "hello" },
    schema = {
      config = {
        get_string = function(_, key)
          if key == "en_ai/dir" then return tmpdir end
          if key == "en_ai/ai_dict" then return aidict end
          if key == "en_ai/width" then return "12" end
          return nil
        end,
      },
    },
  },
}
M.init(env)

local failed = 0
local function check(name, cond, detail)
  if cond then
    print(string.format("  [PASS] %s", name))
  else
    failed = failed + 1
    print(string.format("  [FAIL] %s%s", name, detail and (" -> " .. detail) or ""))
  end
end

print("== en_assoc 测试 ==")

-- 1. 释义行丢掉、释义贴到单词候选的 comment
yielded = {}
M.func(mk_input({ mk_word("hello"), mk_meaning("interj. 喂, 嘿"), mk_meaning("n. 表示问候"),
                   mk_word("help"), mk_meaning("v. 帮助") }), env)
check("释义行被丢掉（剩 2 个候选）", #yielded == 2, "n=" .. #yielded)
check("第 1 个是 hello", yielded[1] and yielded[1].text == "hello")
check("hello 的注释变成释义", yielded[1] and yielded[1].comment == "interj. 喂, 嘿",
      yielded[1] and tostring(yielded[1].comment) or "nil")
check("联想词 help 也带释义", yielded[2] and yielded[2].comment == "v. 帮助",
      yielded[2] and tostring(yielded[2].comment) or "nil")

-- 2. 完整释义记到 en_state（Ctrl+Enter 用）
check("en_state 记下完整释义", state.get_meaning("hello") == "interj. 喂, 嘿",
      tostring(state.get_meaning("hello")))

-- 3. AI 词库里的词同样带释义
env.engine.context.input = "typst"
yielded = {}
M.func(mk_input({ mk_word("typst"), mk_meaning("n. 排版系统"), mk_word("Typst") }), env)
check("AI 词带释义", yielded[1] and yielded[1].comment == "n. 排版系统",
      yielded[1] and tostring(yielded[1].comment) or "nil")
check("大写条目也保留", #yielded == 2 and yielded[2].text == "Typst")

-- 4. 大写词：本地没有 → 补一个单词候选（释义等 AI 或 response.txt）
env.engine.context.input = "Info"
yielded = {}
M.func(mk_input({}), env)
check("大写词补出单词候选", #yielded == 1 and yielded[1].text == "Info",
      yielded[1] and yielded[1].text or "nil")

-- 5. 没有候选时补一个单词候选（AI 词）
env.engine.context.input = "typst"
yielded = {}
M.func(mk_input({}), env)
check("没有候选也能补出单词", #yielded == 1 and yielded[1].text == "typst",
      yielded[1] and yielded[1].text or "nil")
check("补出的候选带释义", yielded[1] and yielded[1].comment == "n. 排版系统",
      yielded[1] and tostring(yielded[1].comment) or "nil")

-- 6. 跑马灯：长释义按窗口滚动（偏移在 en_state 里）
env.engine.context.input = "information"
local function comment_of()
  yielded = {}
  M.func(mk_input({ mk_word("information"), mk_meaning("n. 消息; 知识; 通知; 情报; 信息; 问讯处") }), env)
  return yielded[1] and yielded[1].comment or ""
end
local c1 = comment_of()
local w = utf8.len(c1)
check("跑马灯窗口宽度 = width", w == 12, "len=" .. tostring(w) .. " text=" .. c1)
local c2 = comment_of()
check("不推进就不滚动", c1 == c2, c1 .. " vs " .. c2)
state.bump("information", 4)
local c3 = comment_of()
check("Tab 之后窗口前进了", c3 ~= c2, c2 .. " vs " .. c3)

-- 7. 换词 → 偏移清零
env.engine.context.input = "info"
yielded = {}
M.func(mk_input({ mk_word("information") }), env)
check("换词后偏移清零", state.offset_of("info") == 0,
      "off=" .. tostring(state.offset_of("info")))

-- 8. AI 词库改了之后能读到新释义
write(aidict, table.concat({
  "hello\thello\t10",
  "interj. 喂喂\thello\t0",
  "", }, "\n"))
env.engine.context.input = "hello"
yielded = {}
M.func(mk_input({ mk_word("hello"), mk_meaning("interj. 喂喂") }), env)
check("AI 词库更新后读到新释义", yielded[1] and yielded[1].comment == "interj. 喂喂",
      yielded[1] and tostring(yielded[1].comment) or "nil")

-- 9. 词库里没有的词：候选保留、注释不动
env.engine.context.input = "quux"
yielded = {}
M.func(mk_input({ mk_word("quux") }), env)
check("未收录词保留且不改注释", #yielded == 1 and yielded[1].comment == nil)

os.execute('rm -rf "' .. tmpdir .. '"')

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
