-- test_en_assoc.lua
-- 用法：在 Rime 用户目录下执行  lua test_en_assoc.lua
-- 验证「联想模式」：丢释义行、把释义贴到单词候选尾部；关闭时原样透传。

local script = arg and arg[0] or "test_en_assoc.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/en_assoc.lua")
  if not f then dir = dir .. "/.." else f:close() end
end


package.path = dir .. "/lua/?.lua;" .. package.path   -- 让 require("en_dict_data") 找得到

local ok, M = pcall(dofile, dir .. "/lua/en_assoc.lua")
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 lua/en_assoc.lua 失败: " .. tostring(M))
  os.exit(1)
end

-- ---- 造两个词库文件 ----
local tmpdir = os.tmpname()
os.remove(tmpdir)
os.execute('mkdir -p "' .. tmpdir .. '"')

local base = tmpdir .. "/ecdict.dict.yaml"
local aidict = tmpdir .. "/ai_ecdict.dict.yaml"

local ver = 0
local function write(path, body)
  ver = ver + 1
  local f = io.open(path, "w")
  f:write("#v", ver, "\n", body)     -- 版本号变了 → 共享模块会重读
  f:close()
end

write(base, table.concat({
  "---", "name: ecdict", "...",
  "hello\thello\t10",
  "interj. 喂, 嘿\thello\t0",
  "n. 表示问候\thello\t0",
  "help\thelp\t10",
  "v. 帮助\thelp\t0",
  "held\theld\t10",
  "v. 握住\theld\t0",
  "", }, "\n"))

write(aidict, table.concat({
  "# Rime dictionary", "#v1", "---", "name: ai_ecdict", "...",
  "typst\ttypst\t10",
  "n. 排版系统\ttypst\t0",
  "Typst\tTypst\t10",
  "n. 排版系统\tTypst\t0",
  "", }, "\n"))

-- ---- mock ----
local function mk_cand(text, comment)
  return { text = text, comment = comment, quality = 0, set_comment_called = false }
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
function yield(c) yielded[#yielded + 1] = c end

function Candidate(typ, start, end_, text, comment)
  return { type = typ, start = start, _end = end_, text = text, comment = comment, quality = 0 }
end

local env = {
  engine = {
    context = { get_option = function() return true end },
    schema = {
      config = {
        get_string = function(_, key)
          if key == "en_ai/dir" then return tmpdir end
          if key == "en_ai/base_dict" then return base end
          if key == "en_ai/ai_dict" then return aidict end
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

print("== en_assoc 测试 (" .. dir .. ") ==")

-- 1. 联想模式：单词保留 + 释义进 comment，释义行被丢掉
local cands = {
  mk_cand("hello"),
  mk_cand("interj. 喂, 嘿"),
  mk_cand("n. 表示问候"),
  mk_cand("help", "~p"),
  mk_cand("v. 帮助"),
}
yielded = {}
M.func(mk_input(cands), env)
check("释义行被丢掉（3 个候选剩 2 个）", #yielded == 2, "n=" .. #yielded)
check("第 1 个是 hello", yielded[1] and yielded[1].text == "hello")
check("hello 的注释变成释义", yielded[1] and yielded[1].comment == "interj. 喂, 嘿",
      yielded[1] and tostring(yielded[1].comment) or "nil")
check("联想词 help 也带释义", yielded[2] and yielded[2].comment == "v. 帮助",
      yielded[2] and tostring(yielded[2].comment) or "nil")

-- 2. AI 词库里的词同样带释义
yielded = {}
M.func(mk_input({ mk_cand("typst"), mk_cand("n. 排版系统"), mk_cand("Typst") }), env)
check("AI 词带释义", yielded[1] and yielded[1].comment == "n. 排版系统",
      yielded[1] and tostring(yielded[1].comment) or "nil")
check("大写条目也保留", #yielded == 2 and yielded[2].text == "Typst")

-- 4. AI 词库版本变化后会重读
write(aidict, table.concat({
  "# Rime dictionary", "#v2", "---", "name: ai_ecdict", "...",
  "typst\ttypst\t10",
  "n. 排版系统v2\ttypst\t0",
  "", }, "\n"))
yielded = {}
M.func(mk_input({ mk_cand("typst") }), env)
check("版本变化后重读释义", yielded[1] and yielded[1].comment == "n. 排版系统v2",
      yielded[1] and tostring(yielded[1].comment) or "nil")

-- 5. 词库里没有的词：保留候选但注释不动
yielded = {}
M.func(mk_input({ mk_cand("quux", "~x") }), env)
check("未收录词保留且不改注释", #yielded == 1 and yielded[1].comment == "~x")

-- 5b. 写 cands.tsv（给 Ctrl+Enter 用）
yielded = {}
M.func(mk_input({ mk_cand("hello"), mk_cand("interj. 喂, 嘿"), mk_cand("help") }), env)
local cf = io.open(tmpdir .. "/cands.tsv", "r")
local head = cf and cf:read("*l")
local line1 = cf and cf:read("*l")
if cf then cf:close() end
check("cands.tsv 有内容", line1 ~= nil, tostring(line1))
check("cands.tsv 记录 词+释义", line1 == "hello\tinterj. 喂, 嘿", tostring(line1))

-- 6. 跑马灯：长释义按窗口滚动
write(base, table.concat({
  "---", "name: ecdict", "...",
  "information\tinformation\t10",
  "n. 消息；知识；通知；情报；资料；数据\tinformation\t0",
  "", }, "\n"))
local menv = {
  engine = {
    context = { get_option = function(_, n) return true end, input = "information" },
    schema = { config = { get_string = function(_, key)
      if key == "en_ai/dir" then return tmpdir end
      if key == "en_ai/base_dict" then return base end
      if key == "en_ai/ai_dict" then return aidict end
      if key == "en_ai/width" then return "8" end
      if key == "en_ai/step" then return "1" end
      if key == "en_ai/marquee_auto" then return "0" end
      return nil
    end } },
  },
}
M.init(menv)

local function comment_of()
  yielded = {}
  M.func(mk_input({ mk_cand("information") }), menv)
  return yielded[1] and yielded[1].comment or ""
end

local c1 = comment_of()
local w = utf8.len(c1)
check("跑马灯窗口宽度 = width", w == 8, "len=" .. tostring(w) .. " text=" .. c1)
local c2 = comment_of()
check("手动模式下不自己滚", c1 == c2, c1 .. " vs " .. c2)

-- 模拟按了一次 Tab（写在 scroll.txt 里）
local sf = io.open(tmpdir .. "/scroll.txt", "w")
sf:write("4\ninformation\n")
sf:close()
local c3 = comment_of()
check("Tab 之后窗口前进了", c3 ~= c2, c2 .. " vs " .. c3)
check("窗口内容来自释义", ("n. 消息；知识；通知；情报；资料；数据"):find(c1:gsub("%s+$", ""), 1, true) ~= nil
      or ("n. 消息；知识；通知；情报；资料；数据" .. "    "):find(c1, 1, true) ~= nil,
      c1)

-- 换成别的词 → 偏移清零（scroll.txt 被改写）
local sf2 = io.open(tmpdir .. "/scroll.txt", "w")
sf2:write("9\ninformation\n")
sf2:close()
menv.engine.context.input = "info"
yielded = {}
M.func(mk_input({ mk_cand("information") }), menv)
local rf = io.open(tmpdir .. "/scroll.txt", "r")
local new_off = rf and rf:read("*l")
local new_inp = rf and rf:read("*l")
if rf then rf:close() end
check("换词后偏移清零", new_off == "0", "off=" .. tostring(new_off))
check("换词后记录新输入", new_inp == "info", "input=" .. tostring(new_inp))

-- 7. 词库里没有的词：AI 候选（纯释义）要被换成"单词 + 释义注释"，空格上单词
local aenv = {
  engine = {
    context = {
      get_option = function(_, n) return true end,
      input = "figma",
      composition = { back = function() return { start = 0, _end = 5 } end },
    },
    schema = { config = { get_string = function(_, key)
      if key == "en_ai/base_dict" then return base end
      if key == "en_ai/ai_dict" then return aidict end
      if key == "en_ai/width" then return "40" end
      return nil
    end } },
  },
}
M.init(aenv)
yielded = {}
M.func(mk_input({ mk_cand("n. Figma，在线设计软件") }), aenv)
check("AI 释义不再单独成行", #yielded == 1, "n=" .. #yielded)
check("补出的候选是单词本身", yielded[1] and yielded[1].text == "figma",
      yielded[1] and yielded[1].text or "nil")
check("释义进了注释", yielded[1] and yielded[1].comment == "n. Figma，在线设计软件",
      yielded[1] and tostring(yielded[1].comment) or "nil")

-- 8. 有 AI 词库释义但完全没有候选时，也能补出单词候选
write(aidict, table.concat({
  "# Rime dictionary", "#v9", "---", "name: ai_ecdict", "...",
  "figma\tfigma\t10",
  "n. Figma，在线设计软件\tfigma\t0",
  "", }, "\n"))
yielded = {}
M.func(mk_input({}), aenv)
check("没有候选也能补出单词", #yielded == 1 and yielded[1].text == "figma",
      yielded[1] and yielded[1].text or "nil")
check("释义来自 AI 词库", yielded[1] and yielded[1].comment == "n. Figma，在线设计软件",
      yielded[1] and tostring(yielded[1].comment) or "nil")

-- 9. 精确词已存在时不要重复补
write(base, table.concat({
  "---", "name: ecdict", "...",
  "hello\thello\t10",
  "interj. 喂\thello\t0",
  "", }, "\n"))
aenv.engine.context.input = "hello"
M.init(aenv)
yielded = {}
M.func(mk_input({ mk_cand("hello") }), aenv)
check("已有精确词时不重复", #yielded == 1 and yielded[1].text == "hello",
      "n=" .. #yielded)

os.execute('rm -rf "' .. tmpdir .. '"')

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
