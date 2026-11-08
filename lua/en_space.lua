-- lua/en_space.lua           【英文模式】processor（放在 en_ai_request 之后、ascii_composer 之前）
--
-- 选词上屏时自动补一个尾随空格：打 hello 按空格 → 上屏 "hello "，
-- 接着打下一个词不会粘成 "helloworld"，不用再补一次空格。
--
-- 顺带处理首字母大写：词库里只存小写（大小写靠 schema 的 speller/algebra 派生），
-- 所以打 Hello 时候选正文是 hello。用户敲的是大写，上屏也该是大写，这里补回来。
--
-- 为什么不用 filter 改 cand.text：librime-lua 的 CandidateSet::set_text 只对
-- SimpleCandidate 生效（`if (auto p = dynamic_cast<SimpleCandidate *>(&c))`），
-- 而词库候选是 Phrase，赋值会被静默忽略。所以这里在**提交那一刻**处理：
-- 拿当前高亮候选的文本，自己 commit，然后吃掉按键。
--
-- 开关（两级）：
--   * F4 选单里的「自动空格」（schema switches 的 no_auto_space，反向命名 ——
--     见 english.schema.yaml：不写 reset 才能记住）：关掉后选词不再补空格
--   * en_ai/auto_space: 0     yaml 里的总开关，彻底关（F4 开关也不起作用）
--   * en_ai/auto_space_keys   触发补空格的键（默认 "space,Return"）
--
-- 挂载：english.schema.yaml → engine/processors 的 lua_processor@*en_space

local M = {}

local WORD_RE = "^[%a][%a'%-]*$"

local function cfg_str(cfg, key)
  local v = cfg:get_string(key)
  if v == nil or v == "" then return nil end
  return v
end

function M.init(env)
  local cfg = env.engine.schema.config
  -- 总开关（yaml 里改；F4 那个是运行时开关）
  env.master = (cfg_str(cfg, "en_ai/auto_space") or "1") ~= "0"
  env.keys = {}
  for name in (cfg_str(cfg, "en_ai/auto_space_keys") or "space,Return"):gmatch("[^,%s]+") do
    env.keys[name] = true
  end
end

function M.func(key, env)
  if not env.master then return 2 end
  local ctx = env.engine.context
  if not ctx or not ctx:is_composing() then return 2 end
  -- F4 选单里的开关：no_auto_space 打开 = 不要自动空格
  local ok, off = pcall(function() return ctx:get_option("no_auto_space") end)
  if ok and off then return 2 end
  if not env.keys[key:repr()] then return 2 end

  -- 高亮候选优先；连候选都没有（生僻词）时退回原始输入
  local cand = ctx:get_selected_candidate()
  local typed = ctx.input or ""
  local text = (cand and cand.text) or typed
  text = text:gsub("%s+$", "")              -- 幂等：已有尾随空格不再加
  if text == "" or not text:match(WORD_RE) then
    return 2                                 -- 中文释义 / 标点 / 片段：照旧走 Rime 自己
  end
  -- 输入是大写开头、候选是小写正文 → 上屏也大写（词库只有小写那份）
  if typed:match("^%u") and text:match("^%l") then
    text = text:sub(1, 1):upper() .. text:sub(2)
  end

  env.engine:commit_text(text .. " ")
  ctx:clear()
  return 1                                   -- 吃掉这个按键
end

return M
