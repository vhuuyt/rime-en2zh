-- lua/en_assoc.lua           【英文模式】filter（filters 第一位）
--
-- 把候选改造成"单词 + 尾部释义"：
--   * 释义候选丢掉，改贴到单词候选的 comment 上
--   * 释义超过 en_ai/width 就按窗口滚动（偏移放在 en_state 内存里，Tab 由 processor 推进）
--   * 词库（本地 + AI 补录）里都没有的词，补一个单词候选出来，保证空格上屏的是单词
--   * 完整释义记在 en_state 里，给 Ctrl+Enter 用
--
-- ★ 每次按键不做任何文件写入：滚动偏移、完整释义都放在共享内存模块 en_state。
--   唯一可能读文件的是"本地查不到释义"时读一次 response.txt（AI 结果），很罕见。
--
-- 挂载：english.schema.yaml → engine/filters 的 lua_filter@*en_assoc

local M = {}

local dict_data = require("en_dict_data")
local state = require("en_state")

local WORD_RE = "^[%a][%a'%-]*$"

local function default_dir()
  local tmp = os.getenv("TEMP") or os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
  return tmp:gsub("\\+$", "") .. "/rime_en_ai"
end

local function rime_dir()
  local appdata = os.getenv("APPDATA")
  if appdata then return appdata:gsub("\\", "/") .. "/Rime" end
  return (os.getenv("HOME") or ".") .. "/Library/Rime"
end

local function cfg_str(cfg, key)
  local v = cfg:get_string(key)
  if v == nil or v == "" then return nil end
  return v
end

local function char_at(s, i)
  local a = utf8.offset(s, i)
  if not a then return " " end
  local b = utf8.offset(s, i + 1)
  return s:sub(a, (b or (#s + 1)) - 1)
end

-- 释义太长时按窗口滚动（offset 由 en_state 管）
local function scroll(text, width, offset)
  local n = utf8.len(text) or #text
  if width <= 0 or n <= width then return text end
  local total = n + 4
  local start = offset % total
  local out = {}
  for i = 0, width - 1 do
    local idx = (start + i) % total
    out[#out + 1] = (idx < n) and char_at(text, idx + 1) or " "
  end
  return table.concat(out)
end

-- 桥刚返回的译文（只在"本地没有释义"时才读一次）
local function read_response(dir)
  local f = io.open(dir .. "/response.txt", "r")
  if not f then return nil, nil end
  local word = f:read("*l")
  local text = f:read("*a")
  f:close()
  if not word or word == "" then return nil, nil end
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return word, text
end

local function meaning_for(env, text)
  -- 1) 本地词表（大写词按小写回退）
  local meaning = dict_data.meaning(env.words, text)
  if meaning then return meaning end
  -- 2) 桥刚返回的 AI 译文（每个词只查一次）
  if env.resp_checked ~= text then
    env.resp_checked = text
    local word, got = read_response(env.dir)
    if word == text and got and got ~= "" then
      env.resp_word, env.resp_text = word, got
    end
  end
  if env.resp_word == text then return env.resp_text end
  return nil
end

local function back_segment(ctx)
  local ok, comp = pcall(function() return ctx.composition end)
  if not ok or not comp then return nil end
  local ok2, seg = pcall(function() return comp:back() end)
  if not ok2 then return nil end
  return seg
end

function M.init(env)
  local cfg = env.engine.schema.config
  env.dir = cfg_str(cfg, "en_ai/dir") or default_dir()
  env.base_path = cfg_str(cfg, "en_ai/base_dict") or (rime_dir() .. "/dicts/ecdict.dict.yaml")
  env.ai_path = cfg_str(cfg, "en_ai/ai_dict") or (rime_dir() .. "/dicts/ai_ecdict.dict.yaml")
  env.width = tonumber(cfg_str(cfg, "en_ai/width") or "") or 20
  env.step = tonumber(cfg_str(cfg, "en_ai/step") or "") or 2
  env.marquee = (cfg_str(cfg, "en_ai/marquee") or "1") ~= "0"
  env.words = nil
  env.resp_checked = nil
  env.resp_word = nil
  env.resp_text = nil
end

function M.func(input, env)
  local ctx = env.engine.context
  env.words = dict_data.load(env.base_path, env.ai_path)

  local input_text = ctx.input or ""
  state.clear_meanings()

  -- 先把候选分流：单词留下，释义丢掉（释义拿去当注释）
  local words, seen_exact, dropped_meaning = {}, false, nil
  for cand in input:iter() do
    local text = cand.text or ""
    if text:match(WORD_RE) then
      if text == input_text then seen_exact = true end
      words[#words + 1] = { cand = cand, text = text }
    elseif not dropped_meaning then
      dropped_meaning = text
    end
  end

  -- 词库里都没有这个词（只有 AI 结果）→ 补一个单词候选，保证空格上单词
  if not seen_exact and input_text:match(WORD_RE) then
    local meaning = meaning_for(env, input_text) or dropped_meaning
    if meaning then
      local seg = back_segment(ctx)
      local cand = Candidate("en_ai", seg and seg.start or 0,
                             seg and seg._end or #input_text, input_text, meaning)
      cand.quality = 0.05
      table.insert(words, 1, { cand = cand, text = input_text, meaning = meaning })
    end
  end

  -- 输出：释义贴到 comment，过长则按窗口滚动
  local offset = state.offset_of(input_text)
  for _, item in ipairs(words) do
    local meaning = item.meaning or meaning_for(env, item.text)
    if meaning and meaning ~= item.text then
      state.set_meaning(item.text, meaning)          -- 完整释义存内存，给 Ctrl+Enter
      if env.marquee and (utf8.len(meaning) or #meaning) > env.width then
        item.cand.comment = scroll(meaning, env.width, offset)
      else
        item.cand.comment = meaning
      end
    end
    yield(item.cand)
  end
end

return M
