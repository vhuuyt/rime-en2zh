-- test_en_space.lua
-- 用法：在 Rime 用户目录下执行  lua test_en_space.lua
-- 验证「选词后自动补尾随空格」：空格/回车提交单词时补一个空格，
-- 中文释义/标点不补，可关，幂等。

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

-- ---- mock：key / context / engine ----
local function mk_key(repr)
  return { repr = function() return repr end }
end

local function mk_env(opts)
  opts = opts or {}
  local state = { committed = nil, cleared = 0, refreshed = 0 }
  local options = opts.options or { auto_space = true }
  local ctx = {
    input = opts.input or "",
    _composing = (opts.composing ~= false),
    _cand = opts.cand,
    is_composing = function(self) return self._composing end,
    get_selected_candidate = function(self) return self._cand end,
    get_option = function(self, name) return options[name] and true or false end,
    set_option = function(self, name, v) options[name] = v and true or false end,
    clear = function(self) state.cleared = state.cleared + 1 end,
    refresh_non_confirmed_composition = function(self) state.refreshed = state.refreshed + 1 end,
  }
  local env = {
    engine = {
      context = ctx,
      commit_text = function(_, text) state.committed = text end,
      schema = {
        config = {
          get_string = function(_, key)
            if key == "en_ai/auto_space" then return opts.auto_space end
            if key == "en_ai/auto_space_keys" then return opts.keys end
            return nil
          end,
        },
      },
    },
  }
  M.init(env)
  return env, state
end

local function mk_cand(text)
  return { text = text, comment = nil, quality = 0 }
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

-- 1. 空格提交单词 → 上屏 "hello "
local env, st = mk_env({ cand = mk_cand("hello"), input = "hello" })
local r = M.func(mk_key("space"), env)
check("空格被吃掉（return 1）", r == 1, "r=" .. tostring(r))
check("提交文本带尾随空格", st.committed == "hello ", "[" .. tostring(st.committed) .. "]")
check("提交后清空 composition", st.cleared == 1, "cleared=" .. tostring(st.cleared))

-- 2. 回车同样补空格
local env2, st2 = mk_env({ cand = mk_cand("world"), input = "world" })
M.func(mk_key("Return"), env2)
check("回车也补空格", st2.committed == "world ", "[" .. tostring(st2.committed) .. "]")

-- 3. 其它键放行
local env3, st3 = mk_env({ cand = mk_cand("hello"), input = "hello" })
local r3 = M.func(mk_key("a"), env3)
check("普通字母键放行（return 2）", r3 == 2, "r=" .. tostring(r3))
check("放行时不提交", st3.committed == nil, tostring(st3.committed))

-- 4. 中文释义 / 标点候选不补空格
local env4, st4 = mk_env({ cand = mk_cand("interj. 喂, 嘿"), input = "hello" })
local r4 = M.func(mk_key("space"), env4)
check("中文候选放行", r4 == 2 and st4.committed == nil, "r=" .. tostring(r4))

local env5, st5 = mk_env({ cand = mk_cand(".") })
M.func(mk_key("space"), env5)
check("标点候选不补空格", st5.committed == nil, tostring(st5.committed))

-- 5. 连字符 / 撇号词算单词
local env6, st6 = mk_env({ cand = mk_cand("well-known") })
M.func(mk_key("space"), env6)
check("连字符词补空格", st6.committed == "well-known ", "[" .. tostring(st6.committed) .. "]")

local env7, st7 = mk_env({ cand = mk_cand("don't") })
M.func(mk_key("space"), env7)
check("撇号词补空格", st7.committed == "don't ", "[" .. tostring(st7.committed) .. "]")

-- 6. 幂等：候选已带空格不会再补一个
local env8, st8 = mk_env({ cand = mk_cand("hello ") })
M.func(mk_key("space"), env8)
check("幂等（不会变两个空格）", st8.committed == "hello ", "[" .. tostring(st8.committed) .. "]")

-- 7. 没有候选时退回原始输入
local env9, st9 = mk_env({ cand = nil, input = "quux" })
local r9 = M.func(mk_key("space"), env9)
check("无候选时用原始输入", r9 == 1 and st9.committed == "quux ",
      "r=" .. tostring(r9) .. " [" .. tostring(st9.committed) .. "]")

-- 8. 不在 composing 状态（直通 ASCII）时不干预
local env10, st10 = mk_env({ cand = mk_cand("hello"), composing = false })
local r10 = M.func(mk_key("space"), env10)
check("非输入态放行", r10 == 2 and st10.committed == nil, "r=" .. tostring(r10))

-- 9. 开关关掉就不补
local env11, st11 = mk_env({ cand = mk_cand("hello"), auto_space = "0" })
local r11 = M.func(mk_key("space"), env11)
check("auto_space=0 时不干预", r11 == 2 and st11.committed == nil, "r=" .. tostring(r11))

-- 10. 默认开启（没写配置）
local env12, st12 = mk_env({ cand = mk_cand("hello") })
M.func(mk_key("space"), env12)
check("默认开启", st12.committed == "hello ", "[" .. tostring(st12.committed) .. "]")

-- 11. 自定义触发键：只配 space 时 Return 不补
local env13, st13 = mk_env({ cand = mk_cand("hello"), keys = "space" })
local r13 = M.func(mk_key("Return"), env13)
check("auto_space_keys 只写 space 时 Return 不补", r13 == 2 and st13.committed == nil,
      "r=" .. tostring(r13))

-- 12. 大写词（Typst 之类）也算单词
local env14, st14 = mk_env({ cand = mk_cand("Typst") })
M.func(mk_key("space"), env14)
check("大写词补空格", st14.committed == "Typst ", "[" .. tostring(st14.committed) .. "]")

-- 13. F4 选单里的「自动空格」开关关掉 → 不补
local env15, st15 = mk_env({ cand = mk_cand("hello"), options = { auto_space = false } })
local r15 = M.func(mk_key("space"), env15)
check("F4 关掉自动空格后不补", r15 == 2 and st15.committed == nil, "r=" .. tostring(r15))

-- 14. 总开关关掉（en_ai/auto_space: 0）→ 即使 F4 开着也不补
local env16, st16 = mk_env({ cand = mk_cand("hello"), auto_space = "0", options = { auto_space = true } })
local r16 = M.func(mk_key("space"), env16)
check("yaml 总开关关掉后不补", r16 == 2 and st16.committed == nil, "r=" .. tostring(r16))

-- 15. F4 开着（默认）→ 正常补
local env17, st17 = mk_env({ cand = mk_cand("hello"), options = { auto_space = true } })
M.func(mk_key("space"), env17)
check("F4 开着时正常补", st17.committed == "hello ", "[" .. tostring(st17.committed) .. "]")

print("")
if failed == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failed .. " 项失败")
  os.exit(1)
end
