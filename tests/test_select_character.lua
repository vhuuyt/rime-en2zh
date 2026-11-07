-- test_select_character.lua
-- 用法：在 Rime 用户目录下执行  lua test_select_character.lua
-- 用 mock 的 key/context 验证以词定字。

local script = arg and arg[0] or "test_select_character.lua"
local dir = script:match("^(.*)[/\\][^/\\]*$") or "."

-- 本文件在 tests/ 里，lua 脚本在上一级；自动兼容两种放法
do
  local f = io.open(dir .. "/lua/select_character.lua")
  if not f then dir = dir .. "/.." else f:close() end
end

local target = dir .. "/lua/select_character.lua"

local ok, M = pcall(dofile, target)
if not ok or type(M) ~= "table" or type(M.func) ~= "function" then
  print("[FATAL] 加载 " .. target .. " 失败: " .. tostring(M))
  os.exit(1)
end

-- ---- mock ----
local function mk_key(repr, release)
  return {
    repr = function() return repr end,
    release = function() return release and true or false end,
  }
end

local function mk_env(state)
  local ctx = {
    input = state.input or "",
    cand_text = state.cand_text,
    commit_text = state.commit_text or "",
    is_comp = state.composing ~= false,
    menu = state.menu ~= false,
    committed = {},
    pushed = {},
  }
  function ctx:is_composing() return self.is_comp end
  function ctx:has_menu() return self.menu end
  function ctx:get_selected_candidate()
    if self.cand_text then return { text = self.cand_text } end
    return nil
  end
  function ctx:get_commit_text() return self.commit_text end
  function ctx:clear() self.cleared = true end
  function ctx:push_input(s) self.pushed[#self.pushed + 1] = s end

  local env = {
    engine = {
      context = ctx,
      commit_text = function(_, t) ctx.committed[#ctx.committed + 1] = t end,
      schema = {
        config = {
          get_string = function(_, path)
            if path == "key_binder/select_first_character" then return "bracketleft" end
            if path == "key_binder/select_last_character" then return "bracketright" end
            return nil
          end,
        },
      },
    },
  }
  M.init(env)
  return env, ctx
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

print("== select_character 测试 (" .. target .. ") ==")

-- 1. 取首字 / 末字（UTF-8）
local env, ctx = mk_env({ input = "nihao", cand_text = "你好", commit_text = "你好" })
local r = M.func(mk_key("bracketleft"), env)
check("[ 取首字 → 你", ctx.committed[1] == "你", "got=" .. tostring(ctx.committed[1]))
check("[ 返回 1 (kAccepted)", r == 1, "got=" .. tostring(r))
check("[ 清空输入", ctx.cleared == true)

env, ctx = mk_env({ input = "nihao", cand_text = "你好", commit_text = "你好" })
r = M.func(mk_key("bracketright"), env)
check("] 取末字 → 好", ctx.committed[1] == "好", "got=" .. tostring(ctx.committed[1]))

env, ctx = mk_env({ input = "hello", cand_text = "hello", commit_text = "hello" })
M.func(mk_key("bracketright"), env)
check("] 英文取末字母 → o", ctx.committed[1] == "o", "got=" .. tostring(ctx.committed[1]))

-- 2. 单字候选：原样上屏
env, ctx = mk_env({ input = "wo", cand_text = "我", commit_text = "我" })
M.func(mk_key("bracketleft"), env)
check("单字候选上屏 我", ctx.committed[1] == "我", "got=" .. tostring(ctx.committed[1]))

-- 3. 长句：候选之后还有未处理输入，要还回去
env, ctx = mk_env({ input = "nihao", cand_text = "你", commit_text = "你hao" })
r = M.func(mk_key("bracketleft"), env)
check("长句：先上屏已确认部分", ctx.committed[1] == "你", "got=" .. tostring(ctx.committed[1]))
check("长句：剩余输入退回", ctx.pushed[1] == "hao", "got=" .. tostring(ctx.pushed[1]))

-- 4. 没有候选，退化为对输入本身取字
env, ctx = mk_env({ input = "nihao", cand_text = nil, commit_text = "nihao" })
M.func(mk_key("bracketright"), env)
check("无候选取输入的末字 → o", ctx.committed[1] == "o", "got=" .. tostring(ctx.committed[1]))

-- 5. 不该触发的情形
env, ctx = mk_env({ input = "nihao", cand_text = "你好", commit_text = "你好" })
r = M.func(mk_key("a"), env)
check("普通按键返回 2", r == 2 and #ctx.committed == 0)

env, ctx = mk_env({ input = "nihao", cand_text = "你好", commit_text = "你好" })
r = M.func(mk_key("bracketleft", true), env)
check("释放事件不触发", r == 2 and #ctx.committed == 0)

env, ctx = mk_env({ input = "", cand_text = nil, commit_text = "", composing = false, menu = false })
r = M.func(mk_key("bracketleft"), env)
check("没有输入时不触发", r == 2 and #ctx.committed == 0)

-- 6. 键名可配置（换成 minus / equal 也应工作）
env, ctx = mk_env({ input = "nihao", cand_text = "你好", commit_text = "你好" })
env.first_key, env.last_key = "minus", "equal"
r = M.func(mk_key("minus"), env)
check("改键位后 minus 也能取首字", r == 1 and ctx.committed[1] == "你")
r = M.func(mk_key("bracketleft"), env)
check("改键位后 bracketleft 不再触发", r == 2 and #ctx.committed == 1)

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
