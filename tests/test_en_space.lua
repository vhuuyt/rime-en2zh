-- test_en_space.lua
-- 用法：在 Rime 用户目录下执行  lua tests/test_en_space.lua
-- 验证「选词上屏补尾随空格」+「首字母大写回填」。

local script = arg and arg[0] or "test_en_space.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."
do
  local f = io.open(dir .. "/lua/en_space.lua")
  if not f then dir = dir .. "/.." else f:close() end
end

local ok, M = pcall(dofile, dir .. "/lua/en_space.lua")
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 lua/en_space.lua 失败: " .. tostring(M))
  os.exit(1)
end

local fails = 0
local function check(name, cond, extra)
  if cond then
    print("  [PASS] " .. name)
  else
    fails = fails + 1
    print("  [FAIL] " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
  end
end

-- ---- mock ----
local function mk_env(opts)
  opts = opts or {}
  local ctx = {
    input = opts.input or "",
    cand = opts.cand,
    option = opts.option or {},
    cleared = false,
    is_composing = function() return (opts.input or "") ~= "" end,
    get_selected_candidate = function(self) return self.cand end,
    get_option = function(self, name) return self.option[name] == true end,
    clear = function(self) self.cleared = true end,
  }
  local env
  env = {
    committed = {},
    engine = {
      context = ctx,
      schema = {
        config = {
          get_string = function(_, key)
            local cfg = { ["en_ai/auto_space"] = "1",
                          ["en_ai/auto_space_keys"] = "space,Return" }
            if opts.cfg and opts.cfg[key] ~= nil then return opts.cfg[key] end
            return cfg[key]
          end,
        },
      },
      commit_text = function(self, text) table.insert(env.committed, text) end,
    },
  }
  M.init(env)
  return env, ctx
end

local function mk_key(repr) return { repr = function() return repr end } end

-- 1. 小写词：补一个尾随空格
local env, ctx = mk_env({ input = "hello", cand = { text = "hello" } })
local r = M.func(mk_key("space"), env)
check("空格上屏", env.committed[1] == "hello ", env.committed[1])
check("吃掉按键", r == 1, r)
check("清空组合", ctx.cleared)

-- 2. 首字母大写：输入 Hello、候选正文 hello → 上屏 Hello
env, ctx = mk_env({ input = "Hello", cand = { text = "hello" } })
M.func(mk_key("space"), env)
check("大写输入上屏保留大写", env.committed[1] == "Hello ", env.committed[1])

-- 3. 小写输入 + 大写候选（AI 词那种）→ 不动
env, ctx = mk_env({ input = "figma", cand = { text = "Figma" } })
M.func(mk_key("space"), env)
check("小写输入不强行降级", env.committed[1] == "Figma ", env.committed[1])

-- 4. 回车也补空格
env, ctx = mk_env({ input = "hello", cand = { text = "hello" } })
M.func(mk_key("Return"), env)
check("回车也补空格", env.committed[1] == "hello ", env.committed[1])

-- 5. 已有尾随空格 → 幂等
env, ctx = mk_env({ input = "hello", cand = { text = "hello " } })
M.func(mk_key("space"), env)
check("不重复补空格", env.committed[1] == "hello ", env.committed[1])

-- 6. 中文释义 / 标点 / 片段：放行给 Rime 自己
for _, text in ipairs({ "n. 信息；资料", ",", "#figure(image(\"\"))" }) do
  env, ctx = mk_env({ input = "hello", cand = { text = text } })
  local rr = M.func(mk_key("space"), env)
  check("放行非单词候选: " .. text, rr == 2 and #env.committed == 0, rr)
end

-- 7. F4 里关掉自动空格
env, ctx = mk_env({ input = "hello", cand = { text = "hello" }, option = { no_auto_space = true } })
check("F4 关掉后放行", M.func(mk_key("space"), env) == 2)

-- 8. yaml 里彻底关掉
env, ctx = mk_env({ input = "hello", cand = { text = "hello" },
                    cfg = { ["en_ai/auto_space"] = "0" } })
check("auto_space: 0 完全关闭", M.func(mk_key("space"), env) == 2)

-- 9. 非上屏键不动
env, ctx = mk_env({ input = "hello", cand = { text = "hello" } })
check("非 space/Return 放行", M.func(mk_key("a"), env) == 2)

-- 10. 没有候选（生僻词）时退回原始输入
env, ctx = mk_env({ input = "zzzqqq" })
M.func(mk_key("space"), env)
check("无候选也能上屏原词", env.committed[1] == "zzzqqq ", env.committed[1])

print("")
if fails == 0 then print("全部通过") else print(fails .. " 项失败") end
os.exit(fails == 0 and 0 or 1)
