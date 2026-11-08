-- test_en_ai.lua
-- 用法：在 Rime 用户目录下执行  lua test_en_ai.lua
-- 用真实文件（临时目录）验证 en_ai_request / en_ai_candidate 的文件协议。

local script = arg and arg[0] or "test_en_ai.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/en_ai_request.lua")
  if not f then dir = dir .. "/.." else f:close() end
end


package.path = dir .. "/lua/?.lua;" .. package.path   -- 让 require("en_dict_data") 找得到

local ok1, req = pcall(dofile, dir .. "/lua/en_ai_request.lua")
local ok2, cand = pcall(dofile, dir .. "/lua/en_ai_candidate.lua")
if not (ok1 and ok2) then
  print("[FATAL] 加载失败: " .. tostring(req) .. " " .. tostring(cand))
  os.exit(1)
end

-- ---- 用临时目录当桥接目录 ----
local is_windows = package.config:sub(1, 1) == "\\"
local function mkdir(d)
  local cmd = is_windows and ('mkdir "' .. d .. '" >nul 2>&1') or ('mkdir -p "' .. d .. '"')
  os.execute(cmd)
end
local function rmdir(d)
  local cmd = is_windows and ('rmdir /s /q "' .. d .. '" >nul 2>&1') or ('rm -rf "' .. d .. '"')
  os.execute(cmd)
end

local bridge = os.tmpname()
os.remove(bridge)
bridge = bridge .. "_dir"
mkdir(bridge)

local function mk_env(module, opts)
  local cfg = {
    get_string = function(_, path)
      local map = {
        ["en_ai/dir"] = bridge,
        ["en_ai/delay_ms"] = tostring(opts.delay or 900),
        ["en_ai/trigger"] = opts.trigger or "",
        ["en_ai/marker"] = "[AI]",
        ["en_ai/min_input_len"] = "2",
        ["en_ai/ai_dict"] = bridge .. "/ai_ecdict.dict.yaml",
        ["en_ai/base_dict"] = bridge .. "/ecdict.dict.yaml",
        ["en_ai/tab"] = "Tab",
        ["en_ai/tab_step"] = "4",
        ["en_ai/commit_key"] = "Control+Return",
        ["en_ai/delete_key"] = "Control+Delete",
        ["en_ai/delete_key_alt"] = "Control+BackSpace",
        ["en_ai/delete_close"] = "1",
        ["en_ai/profiles"] = "minimax,openai",
        ["en_ai/ai_dict"] = bridge .. "/ai_ecdict.dict.yaml",
        ["en_ai/base_dict"] = bridge .. "/ecdict.dict.yaml",
      }
      return map[path]
    end,
  }
  local ctx = {
    cand = nil,
    input = opts.input or "",
    comp = opts.composing ~= false,
    ai = opts.ai ~= false,
    refreshed = 0,
  }
  function ctx:is_composing() return self.comp end
  function ctx:get_option(name)
    if name == "ai_translate" then return self.ai end
    return self.options and self.options[name] or false
  end
  function ctx:refresh_non_confirmed_composition() self.refreshed = self.refreshed + 1 end
  function ctx:get_selected_candidate() return self.cand end

  ctx.committed = {}
  function ctx:clear() self.cleared = true end
  local env = { engine = {
    context = ctx,
    schema = { config = cfg },
    commit_text = function(_, text) ctx.committed[#ctx.committed + 1] = text end,
  } }
  if module.init then module.init(env) end
  return env, ctx
end

local function mk_key(repr)
  return { repr = function() return repr end }
end

local function read_request()
  local f = io.open(bridge .. "/request.txt", "r")
  if not f then return nil end
  local word = f:read("*l")
  local delay = f:read("*l")
  f:close()
  return word, delay
end

local function write_response(word, text)
  local f = io.open(bridge .. "/response.txt", "w")
  f:write(word, "\n", text, "\n")
  f:close()
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

-- 本地词库（mock）
local function write_base(rows, ver)
  local f = io.open(bridge .. "/ecdict.dict.yaml", "w")
  f:write("#v", ver or "1", "\n")
  for _, r in ipairs(rows) do f:write(r, "\n") end
  f:close()
end
write_base({ "hello\thello\t10", "interj. 喂；嘿\thello\t0",
              "info\tinfo\t10", "n. 信息；资料\tinfo\t0" }, 1)

print("== en_ai 测试 (" .. bridge .. ") ==")

-- ---------- 请求侧 ----------
-- 现在 AI 只由 Tab 触发：打字过程中不应该有任何文件写入
local env, ctx = mk_env(req, { input = "hel" })
local r = req.func(mk_key("l"), env)
check("处理器不吞键（返回 2）", r == 2, "r=" .. tostring(r))
ctx.input = "hello"
req.func(mk_key("o"), env)
check("打字不再写 request.txt", read_request() == nil)

-- 太短的词不写
ctx.input = "h"
req.func(mk_key("h"), env)
check("打字不写 request.txt", read_request() == nil)

-- F24 触发重绘并被吞掉
env, ctx = mk_env(req, { input = "hello" })
r = req.func(mk_key("F24"), env)
check("F24 返回 1 (kAccepted)", r == 1, "r=" .. tostring(r))
check("F24 触发候选重绘", ctx.refreshed == 1, "n=" .. tostring(ctx.refreshed))

-- AI 关闭时不写请求
env, ctx = mk_env(req, { input = "hello", ai = false })
req.func(mk_key("o"), env)
check("AI 关闭不请求", read_request() == nil)

-- AI 档位跟着方案选单（单选组 ai_profile）走，不再有快捷键
local function profile()
  local f = io.open(bridge .. "/ai_profile.txt", "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

os.remove(bridge .. "/ai_profile.txt")
env, ctx = mk_env(req, { input = "hello" })
req.func(mk_key("a"), env)
check("默认选中第 1 档", profile() == "minimax", tostring(profile()))

ctx.options = { ai_openai = true }
env, ctx = mk_env(req, { input = "hello" })
env.engine.context.options = { ai_openai = true }
req.func(mk_key("a"), env)
check("选单里选 openai → 档位跟着变", profile() == "openai", tostring(profile()))

env, ctx = mk_env(req, { input = "hello" })
env.engine.context.options = { ai_minimax = true }
req.func(mk_key("a"), env)
check("切回 minimax", profile() == "minimax", tostring(profile()))

-- Ctrl+Delete：只删 AI 词库里的词
local function write_ai_dict(rows, ver)
  local f = io.open(bridge .. "/ai_ecdict.dict.yaml", "w")
  f:write("# Rime dictionary\n# encoding: utf-8\n#v", ver or "1", "\n---\nname: ai_ecdict\n...\n")
  for _, r in ipairs(rows) do f:write(r, "\n") end
  f:close()
end
local function read_file(p)
  local f = io.open(p, "r")
  if not f then return "" end
  local t = f:read("*a")
  f:close()
  return t
end

env, ctx = mk_env(req, { input = "figma" })
write_ai_dict({
  "figma\tfigma\t10",
  "n. Figma，在线设计软件\tfigma\t0",
  "Figma\tFigma\t10",
  "n. Figma，在线设计软件\tFigma\t0",
  "hello\thello\t10",
})
ctx.cand = { text = "figma" }
local dr = req.func(mk_key("Control+Delete"), env)
local body = read_file(bridge .. "/ai_ecdict.dict.yaml")
check("Ctrl+Delete 删掉 AI 词", dr == 1, "r=" .. tostring(dr))
check("小写条目被删", not body:find("figma\tfigma", 1, true), body)
check("大写条目一起删", not body:find("Figma\tFigma", 1, true), body)
check("释义行一起删", not body:find("Figma，在线设计软件", 1, true), body)
check("别的词保留", body:find("hello\thello", 1, true) ~= nil)
check("版本号被抬高", body:find("#v1\n", 1, true) == nil)
check("删完收起候选框", ctx.cleared == true)
check("删完不再重绘（直接收工）", ctx.refreshed == 0, "n=" .. tostring(ctx.refreshed))

-- macOS 风格：Control+BackSpace 也认
env, ctx = mk_env(req, { input = "figma" })
write_ai_dict({ "figma\tfigma\t10", "n. 设计软件\tfigma\t0" })
ctx.cand = { text = "figma" }
local dalt = req.func(mk_key("Control+BackSpace"), env)
check("Control+BackSpace 也能删", dalt == 1, "r=" .. tostring(dalt))

-- 基库里的词不能删
env, ctx = mk_env(req, { input = "hello" })
write_ai_dict({ "figma\tfigma\t10" })
ctx.cand = { text = "hello" }
local dr2 = req.func(mk_key("Control+Delete"), env)
check("基库词不删、放行", dr2 == 2, "r=" .. tostring(dr2))
check("AI 词库没被动", read_file(bridge .. "/ai_ecdict.dict.yaml"):find("figma\tfigma", 1, true) ~= nil)

-- Ctrl+Enter：把高亮候选的释义上屏
local function write_cands(rows)
  local f = io.open(bridge .. "/cands.tsv", "w")
  f:write("0\n")
  for _, r in ipairs(rows) do f:write(r, "\n") end
  f:close()
end

env, ctx = mk_env(req, { input = "hello" })
write_cands({ "hello\tinterj. 喂；嘿", "help\tv. 帮助" })
ctx.cand = { text = "hello" }
local cr = req.func(mk_key("Control+Return"), env)
check("Ctrl+Enter 上屏释义", ctx.committed[1] == "interj. 喂；嘿",
      "got=" .. tostring(ctx.committed[1]))
check("Ctrl+Enter 返回 1", cr == 1, "r=" .. tostring(cr))
check("Ctrl+Enter 清空输入", ctx.cleared == true)

-- 高亮的是别的候选，就上屏那个词的释义
env, ctx = mk_env(req, { input = "hel" })
write_cands({ "hello\tinterj. 喂；嘿", "help\tv. 帮助" })
ctx.cand = { text = "help" }
req.func(mk_key("Control+Return"), env)
check("上屏高亮候选的释义", ctx.committed[1] == "v. 帮助", "got=" .. tostring(ctx.committed[1]))

-- 没有对应释义 → 放行
env, ctx = mk_env(req, { input = "hello" })
write_cands({})
ctx.cand = { text = "hello" }
local cr2 = req.func(mk_key("Control+Return"), env)
check("没有释义时放行", cr2 == 2 and #ctx.committed == 0, "r=" .. tostring(cr2))

-- Tab 滚动：scroll.txt 里有当前词才吃掉 Tab
local function write_scroll(offset, input)
  local f = io.open(bridge .. "/scroll.txt", "w")
  f:write(tostring(offset), "\n", input, "\n")
  f:close()
end
local function read_scroll()
  local f = io.open(bridge .. "/scroll.txt", "r")
  if not f then return nil, nil end
  local off = f:read("*l")
  local inp = f:read("*l")
  f:close()
  return off, inp
end

env, ctx = mk_env(req, { input = "information" })
write_scroll(0, "information")
local r0 = req.func(mk_key("Tab"), env)
local off1 = read_scroll()
check("有长释义时 Tab 被吃掉", r0 == 1, "r=" .. tostring(r0))
check("Tab 让偏移 +4", off1 == "4", "got=" .. tostring(off1))
check("Tab 触发候选重绘", ctx.refreshed == 1, "n=" .. tostring(ctx.refreshed))

env, ctx = mk_env(req, { input = "hello" })
write_scroll(0, "information")            -- 偏移属于别的词
local r1 = req.func(mk_key("Tab"), env)
check("词不匹配时 Tab 放行", r1 == 2, "r=" .. tostring(r1))


-- Tab 三种情况
-- (a) 有长释义 → 滚动（scroll.txt 里有当前词）
-- (b) 有短释义 → 放行
-- (c) 没有释义 → 触发 AI 请求（request.txt 写成 delay 0）
env, ctx = mk_env(req, { input = "hello" })
write_scroll(0, "hello")
local ra = req.func(mk_key("Tab"), env)
check("有长释义：Tab 被吃掉并滚动", ra == 1, "r=" .. tostring(ra))

env, ctx = mk_env(req, { input = "hello" })
os.remove(bridge .. "/scroll.txt")
os.remove(bridge .. "/request.txt")
local rb = req.func(mk_key("Tab"), env)
local reqw = read_request()
check("有短释义：Tab 放行", rb == 2, "r=" .. tostring(rb))
check("有短释义：不发 AI 请求", reqw == nil, "got=" .. tostring(reqw))

env, ctx = mk_env(req, { input = "zzzqqq" })
os.remove(bridge .. "/scroll.txt")
os.remove(bridge .. "/request.txt")
local rc = req.func(mk_key("Tab"), env)
local w2, d2 = read_request()
check("没有释义：Tab 触发 AI", rc == 1, "r=" .. tostring(rc))
check("AI 请求是当前词", w2 == "zzzqqq", "got=" .. tostring(w2))
check("AI 请求 delay=0（立即发）", d2 == "0", "got=" .. tostring(d2))

-- 非字母键（导航/选词）要写暂停标记，让跑马灯停下来
env, ctx = mk_env(req, { input = "hello" })
os.remove(bridge .. "/marquee_pause.txt")
req.func(mk_key("Down"), env)
local pf = io.open(bridge .. "/marquee_pause.txt", "r")
check("非字母键写暂停标记", pf ~= nil)
if pf then pf:close() end
os.remove(bridge .. "/marquee_pause.txt")
env, ctx = mk_env(req, { input = "hello" })
req.func(mk_key("a"), env)
pf = io.open(bridge .. "/marquee_pause.txt", "r")
check("字母键不写暂停标记", pf == nil)
if pf then pf:close() end

-- ---------- 候选侧 ----------
local yielded = {}
function Candidate(typ, start, end_, text, comment)
  return { type = typ, start = start, _end = end_, text = text, comment = comment, quality = 0 }
end
function yield(c) yielded[#yielded + 1] = c end

local seg = { start = 0, _end = 5 }
os.remove(bridge .. "/ai_profile.txt")          -- 先按"没切过档"来测
local cenv = mk_env(cand, { input = "hello" })

-- AI 关闭 → 不补
local cenv_off = mk_env(cand, { input = "hello", ai = false })
yielded = {}
cand.func("hello", seg, cenv_off)
check("AI 关闭不补候选", #yielded == 0)

-- 空响应不补
write_response("empty", "")
yielded = {}
cand.func("empty", seg, cenv)
check("空译文不补候选", #yielded == 0)

-- 大写词：按小写回退补一条候选
yielded = {}
cand.func("Info", seg, cenv)
check("大写词补出候选", #yielded == 1, "n=" .. #yielded)
check("大写候选保留原样", yielded[1] and yielded[1].text == "Info",
      yielded[1] and yielded[1].text or "nil")
check("大写候选带小写释义", yielded[1] and yielded[1].comment == "n. 信息；资料",
      yielded[1] and tostring(yielded[1].comment) or "nil")

yielded = {}
cand.func("HELLO", seg, cenv)
check("全大写也能查到", #yielded == 1 and yielded[1].text == "HELLO")

-- 小写词交给 table_translator，这里不重复出候选
yielded = {}
cand.func("hello", seg, cenv)
check("小写词不由这里出候选", #yielded == 0, "n=" .. #yielded)

rmdir(bridge)

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
