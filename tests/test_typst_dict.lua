-- test_typst_dict.lua
-- 用法：在 Rime 用户目录下执行  lua test_typst_dict.lua
--
-- 这个测试**不硬编码**片段内容：期望值全部从 lua/typst_dict.lua 的 entries 里推导，
-- 所以你随时往表里加/改片段都不会把测试弄红。

local script = arg and arg[0] or "test_typst_dict.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/typst_dict.lua")
  if not f then dir = dir .. "/.." else f:close() end
end

local target = dir .. "/lua/typst_dict.lua"

local ok, M = pcall(dofile, target)
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 " .. target .. " 失败: " .. tostring(M))
  os.exit(1)
end

-- ---- mock librime-lua 全局 ----
local out = {}

function Candidate(typ, start, end_, text, comment)
  return { type = typ, start = start, _end = end_, text = text,
           comment = comment, quality = 0 }
end

function yield(c)
  out[#out + 1] = c
end

local function mk_env(trigger)
  local cfg = {
    get_string = function(_, path)
      if path == "typst_dict/trigger" then return trigger end
      return nil
    end,
  }
  local env = { name_space = "*typst_dict", engine = { schema = { config = cfg } } }
  M.init(env)
  return env
end

local seg = { start = 0, _end = 3 }

local failed = 0
local function check(name, cond, detail)
  if cond then
    print(string.format("  [PASS] %s", name))
  else
    failed = failed + 1
    print(string.format("  [FAIL] %s%s", name, detail and (" -> " .. detail) or ""))
  end
end

local function run(input, env)
  out = {}
  M.func(input, seg, env)
  return out
end

print("== typst_dict 测试 (" .. target .. ") ==")

local env = mk_env(nil)
local entries = env.entries
check("entries 非空", type(entries) == "table" and #entries > 0, "n=" .. tostring(#entries))
check("trigger 缺省为 typ", env.trigger == "typ", "got=" .. tostring(env.trigger))

-- 从表里挑第一个条目做基准
local first = entries[1]
local second = entries[2]

-- 1. 只敲 trigger → 整表展开，顺序与表一致
local r = run("typ", env)
check("typ 展开全部片段", #r == #entries, "got=" .. #r .. " want=" .. #entries)
check("typ 首项与表内第一条一致", r[1] and r[1].text == first[2],
      (r[1] and r[1].text or "nil") .. " vs " .. tostring(first[2]))
check("候选 quality 够高（压过同音词）", r[1] and r[1].quality >= 900,
      r[1] and tostring(r[1].quality) or "nil")
check("候选 type/区间正确", r[1] and r[1].type == "typst" and r[1].start == 0 and r[1]._end == 3)
check("候选带注释", r[1] and type(r[1].comment) == "string" and r[1].comment ~= "")

-- 2. 精确命中 → 排第一；同时会带出以它为前缀的更长的 key
local exact_want = 0
for _, e in ipairs(entries) do
  if e[1]:sub(1, #first[1]) == first[1] then exact_want = exact_want + 1 end
end
r = run("typ" .. first[1], env)
check("精确命中数量正确", #r == exact_want, "got=" .. #r .. " want=" .. exact_want)
check("精确命中排第一", r[1] and r[1].text == first[2], r[1] and r[1].text or "nil")

-- 3. 前缀过滤（用表内第二条的前 2 个字母）
local suffix = second[1]:sub(1, 2)
local want = 0
for _, e in ipairs(entries) do
  if e[1]:sub(1, #suffix) == suffix then want = want + 1 end
end
r = run("typ" .. suffix, env)
check("前缀过滤数量正确 (" .. suffix .. ")", #r == want, "got=" .. #r .. " want=" .. want)
local all_match = true
for _, c in ipairs(r) do
  if c.comment == nil then all_match = false end
end
check("前缀过滤候选均带注释", all_match)

-- 4. 没有命中
check("typzzz 无候选", #run("typzzz", env) == 0)
check("ty 太短不触发", #run("ty", env) == 0)
check("普通拼音不干扰", #run("nihao", env) == 0)

-- 5. trigger 可配置
local env2 = mk_env("tpx")
check("自定义 trigger 生效", env2.trigger == "tpx", "got=" .. tostring(env2.trigger))
r = run("tpx" .. first[1], env2)
check("自定义 trigger 下精确命中", #r >= 1 and r[1].text == first[2])
check("旧 trigger 失效", #run("typ" .. first[1], env2) == 0)

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
