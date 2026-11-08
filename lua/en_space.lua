-- lua/en_space.lua           【英文模式】filter（filters 第二位）
--
-- 给英文单词候选补一个尾随空格：选词上屏后提交的是 "hello "，
-- 接着打下一个词不会粘成 "helloworld"（英文连打不用再按一次空格）。
--
-- 只补「纯英文单词」候选（^[%a][%a'%-]*$）；中文释义、标点不动。
-- 开关：en_ai/auto_space（1 = 补，0 = 不补）。
--
-- 注意：候选文本变了以后，凡是拿 cand.text 去查表的地方都要把尾随空格去掉
--       （en_ai_request.lua 里的 Ctrl+Enter / Ctrl+Delete 都 trim 过）。
--
-- 挂载：english.schema.yaml → engine/filters 的 lua_filter@*en_space

local M = {}

local WORD_RE = "^[%a][%a'%-]*$"

function M.init(env)
  local cfg = env.engine.schema.config
  local v = cfg:get_string("en_ai/auto_space")
  env.auto = (v == nil or v == "") or (v ~= "0")
end

function M.func(input, env)
  for cand in input:iter() do
    local text = cand.text or ""
    if env.auto and text:match(WORD_RE) then
      cand.text = text .. " "
    end
    yield(cand)
  end
end

return M
