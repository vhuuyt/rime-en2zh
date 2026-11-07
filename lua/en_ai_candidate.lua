-- lua/en_ai_candidate.lua    【英文模式】translator
--
-- 作用：补一条候选。词库是全小写的，所以大写词（Info / Typst）查不到，
-- 这里按小写形式回退，补一条「原样大写 + 小写释义」的候选。
--
-- AI 译文不在这里出候选 —— 它由 lua/en_assoc.lua（filter）折进候选注释，
-- 这样候选栏里始终是「单词 + 释义」两栏，不会多出一行中文。
--
-- 不联网、不阻塞。

local M = {}

local dict_data = require("en_dict_data")

local function default_base_dict()
  local appdata = os.getenv("APPDATA")
  if appdata then
    return appdata:gsub("\\", "/") .. "/Rime/dicts/ecdict.dict.yaml"
  end
  return (os.getenv("HOME") or ".") .. "/Library/Rime/dicts/ecdict.dict.yaml"
end

local function cfg_str(cfg, key)
  local v = cfg:get_string(key)
  if v == nil or v == "" then return nil end
  return v
end

function M.init(env)
  local cfg = env.engine.schema.config
  env.base_path = cfg_str(cfg, "en_ai/base_dict") or default_base_dict()
  env.cache = {}
end

function M.func(input, seg, env)
  if input == nil or input == "" then return end
  local ctx = env.engine.context
  if not ctx:get_option("ai_translate") then return end

  local lower = input:lower()
  if lower == input then
    return                    -- 全小写：词库能查到，交给 table_translator
  end

  local words = dict_data.load(env.base_path, env.ai_path)
  local meaning = dict_data.meaning(words, lower)
  if not meaning then
    return
  end

  local cand = Candidate("en_case", seg.start, seg._end, input, meaning)
  cand.quality = 0.5
  yield(cand)
end

return M
