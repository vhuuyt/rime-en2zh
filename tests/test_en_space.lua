-- test_en_space.lua
-- 用法：在 Rime 用户目录下执行  lua test_en_space.lua
-- 验证「选词后自动补尾随空格」：英文单词候选补一个空格，中文/标点不动，可关。

local script = arg and arg[0] or "test_en_space.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/en_space.lua")
  if not f then dir = dir .. "/.." else f:close() end
end

local ok, M = pcall(dofile, dir .. "/lua/en_space.lua")
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 lua/en_space.lua 失败: " .. tostring(M))
  os.exit(1)
end

local function mk_cand(text)
  return { text = text, comment = nil, quality = 0 }
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

local function mk_env(auto_space)
  local env = {
    engine = {
      schema = {
        config = {
          get_string = function(_, key)
            if key == "en_ai/auto_space" then return auto_space end
            return nil
          end,
        },
      },
    },
  }
  M.init(env)
  return env
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

print("== en_space 测试 (" .. dir .. ") ==")

-- 1. 英文单词候选补一个尾随空格
local env = mk_env("1")
yielded = {}
M.func(mk_input({ mk_cand("hello"), mk_cand("help") }), env)
check("单词候选补上空格", yielded[1] and yielded[1].text == "hello ",
      yielded[1] and ("[" .. yielded[1].text .. "]") or "nil")
check("第二个单词也补上空格", yielded[2] and yielded[2].text == "help ",
      yielded[2] and ("[" .. yielded[2].text .. "]") or "nil")
check("候选数量不变", #yielded == 2, "n=" .. #yielded)

-- 2. 中文释义 / 标点不动
yielded = {}
M.func(mk_input({ mk_cand("interj. 喂, 嘿"), mk_cand("."), mk_cand("n. 消息") }), env)
check("中文释义不加空格", yielded[1] and yielded[1].text == "interj. 喂, 嘿",
      yielded[1] and ("[" .. yielded[1].text .. "]") or "nil")
check("标点不加空格", yielded[2] and yielded[2].text == ".",
      yielded[2] and ("[" .. yielded[2].text .. "]") or "nil")
check("中文候选不加空格", yielded[3] and yielded[3].text == "n. 消息",
      yielded[3] and ("[" .. yielded[3].text .. "]") or "nil")

-- 3. 带连字符 / 撇号的词也算单词
yielded = {}
M.func(mk_input({ mk_cand("well-known"), mk_cand("don't") }), env)
check("连字符词补空格", yielded[1] and yielded[1].text == "well-known ",
      yielded[1] and ("[" .. yielded[1].text .. "]") or "nil")
check("撇号词补空格", yielded[2] and yielded[2].text == "don't ",
      yielded[2] and ("[" .. yielded[2].text .. "]") or "nil")

-- 4. 已经有空格的不重复补
yielded = {}
M.func(mk_input({ mk_cand("hello ") }), env)
check("幂等：不会补成两个空格", yielded[1] and yielded[1].text == "hello ",
      yielded[1] and ("[" .. yielded[1].text .. "]") or "nil")

-- 5. 开关关掉就不补
local env0 = mk_env("0")
yielded = {}
M.func(mk_input({ mk_cand("hello") }), env0)
check("auto_space=0 时不补空格", yielded[1] and yielded[1].text == "hello",
      yielded[1] and ("[" .. yielded[1].text .. "]") or "nil")

-- 6. 没写配置（nil）时默认补
local envd = { engine = { schema = { config = { get_string = function() return nil end } } } }
M.init(envd)
yielded = {}
M.func(mk_input({ mk_cand("hello") }), envd)
check("默认开启", yielded[1] and yielded[1].text == "hello ",
      yielded[1] and ("[" .. yielded[1].text .. "]") or "nil")

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
