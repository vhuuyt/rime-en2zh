-- lua/en_space.lua           【英文模式】processor（放在 en_ai_request 之后、ascii_composer 之前）
--
-- 选词上屏时自动补一个尾随空格：打 hello 按空格 → 上屏 "hello "，
-- 接着打下一个词不会粘成 "helloworld"，不用再补一次空格。
--
-- 为什么不用 filter 改 cand.text？
--   librime-lua 的 CandidateSet::set_text 只对 SimpleCandidate 生效：
--       void set_text(T &c, const string &v) {
--         if (auto p = dynamic_cast<SimpleCandidate *>(&c)) p->set_text(v);
--       }
--   而词库（table_translator）给出的候选是 Phrase，赋值会被**静默忽略**，
--   所以「挂个 filter 给 cand.text 加空格」看着部署成功、实际什么都没改。
--   （cand.comment 不同：set_comment 同时处理 Phrase 和 SimpleCandidate，
--     所以释义能正常贴到候选尾巴上。）
--
-- 这里改在**提交那一刻**处理：拿当前高亮候选的文本，自己 commit，然后吃掉按键。
--
-- 开关：en_ai/auto_space      1 = 开（默认），0 = 关
--      en_ai/auto_space_keys 触发补空格的键（默认 "space,Return"）
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
  env.auto = (cfg_str(cfg, "en_ai/auto_space") or "1") ~= "0"
  env.keys = {}
  for name in (cfg_str(cfg, "en_ai/auto_space_keys") or "space,Return"):gmatch("[^,%s]+") do
    env.keys[name] = true
  end
end

function M.func(key, env)
  if not env.auto then return 2 end
  local ctx = env.engine.context
  if not ctx or not ctx:is_composing() then return 2 end
  if not env.keys[key:repr()] then return 2 end

  -- 高亮候选优先；连候选都没有（生僻词）时退回原始输入
  local cand = ctx:get_selected_candidate()
  local text = (cand and cand.text) or ctx.input or ""
  text = text:gsub("%s+$", "")              -- 幂等：已有尾随空格不再加
  if text == "" or not text:match(WORD_RE) then
    return 2                                 -- 中文释义 / 标点 / 片段：照旧走 Rime 自己
  end

  env.engine:commit_text(text .. " ")
  ctx:clear()
  return 1                                   -- 吃掉这个按键
end

return M
