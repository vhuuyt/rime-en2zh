-- lua/en_assoc.lua           【英文模式】filter（filters 第一位）
--
-- 把候选改造成"单词 + 尾部释义"：
--
--   词典里，一个词的释义本来就是**紧跟在这个词的候选后面**的另几条候选
--   （生成器就是这么排的：word<TAB>word<TAB>10 换行 释义<TAB>word<TAB>0 …）。
--   所以这里不需要查任何表：
--     * 认出"单词候选"和"释义候选" → 释义搬到单词的 comment 上，释义自己丢掉
--     * 释义超过 en_ai/width 就按窗口滚动（偏移放在 en_state 内存里，Tab 由 processor 推进）
--     * 词库里没有这个词（只有 AI 结果）→ 补一个单词候选，保证空格上屏的是单词
--     * 完整释义记在 en_state 里，给 Ctrl+Enter 用
--
-- ★ 为什么"单词候选"和"释义候选"能分开？
--   两条线索，任意一条成立就算单词候选：
--     1) 质量大：词库里的单词行权重 10（质量≈22026），释义行权重 0（质量≈1）
--     2) 文本像纯单词：^[%a][%a'-]*$  （释义多是「n. 消息」这种，不会像单词）
--   第 2 条是兜底：万一你手写词条时权重填错，词也不会消失。
--
-- ★ 每次按键不做任何文件写入：滚动偏移、完整释义都放在共享内存模块 en_state。
--   唯一可能读文件的是"本地查不到释义"时读一次 response.txt（AI 结果），很罕见。

local M = {}

local state = require("en_state")

local WORD_RE = "^[%a][%a'%-]*$"
local MARK = "\1"               -- 释义行标记（词库生成时写在文本前）

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

-- ---------------------------------------------------------------- AI 词库（小）
-- 只读 ai_ecdict.dict.yaml（桥自动写的那些词，通常几十条）→ 词 → 释义
-- 大词库（ecdict / chem）不读：它们的释义就在候选流里，不用查表。
local function load_ai_dict(path)
  local words = {}
  local f = io.open(path, "r")
  if not f then return words end
  for line in f:lines() do
    if line:sub(1, 1) ~= "#" and line:find("\t", 1, true) then
      local c1, c2 = line:match("^([^\t]*)\t([^\t]*)")
      if c1 and c1:sub(1, 1) == MARK then c1 = c1:sub(2) end
      if c1 and c2 and c1 ~= "" and c2 ~= "" and c1 ~= c2 then
        local slot = words[c2]
        if not slot then slot = {}; words[c2] = slot end
        if slot.meaning == nil then slot.meaning = c1 end
      end
    end
  end
  f:close()
  return words
end

local function ai_version(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local ver = ""
  for _ = 1, 8 do
    local line = f:read("*l")
    if not line then break end
    local v = line:match("^#v(%d+)")
    if v then ver = v break end
  end
  f:close()
  return ver
end

local function ai_dict(env)
  local ver = ai_version(env.ai_path)
  if env.ai_ver == ver then return env.ai_words end
  env.ai_ver = ver
  env.ai_words = load_ai_dict(env.ai_path)
  return env.ai_words
end

-- 释义来源：AI 词库 → 桥刚返回的译文
local function meaning_for(env, text)
  local slot = ai_dict(env)[text]
  if slot and slot.meaning then return slot.meaning end
  local lower = text:lower()
  if lower ~= text then
    slot = ai_dict(env)[lower]
    if slot and slot.meaning then return slot.meaning end
  end
  -- 桥刚返回的译文（每个词只查一次）
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
  env.ai_path = cfg_str(cfg, "en_ai/ai_dict") or (rime_dir() .. "/dicts/ai_ecdict.dict.yaml")
  env.width = tonumber(cfg_str(cfg, "en_ai/width") or "") or 20
  env.marquee = (cfg_str(cfg, "en_ai/marquee") or "1") ~= "0"
  env.ai_ver = nil
  env.ai_words = nil
  env.resp_checked = nil
  env.resp_word = nil
  env.resp_text = nil
end

local function strip_mark(text)
  if text:sub(1, 1) == MARK then return text:sub(2) end
  return text
end

function M.func(input, env)
  local ctx = env.engine.context
  local input_text = ctx.input or ""
  state.clear_meanings()

  local offset = state.offset_of(input_text)
  local pending = nil          -- 待配释义的单词候选
  local seen_exact = false
  local dropped = nil          -- 孤立的释义（没有对应的单词行）

  local function apply_comment(cand, meaning)
    if not meaning or meaning == "" or meaning == cand.text then return end
    state.set_meaning(cand.text, meaning)          -- 完整释义存内存，给 Ctrl+Enter
    if env.marquee and (utf8.len(meaning) or #meaning) > env.width then
      cand.comment = scroll(meaning, env.width, offset)
    else
      cand.comment = meaning
    end
  end

  for cand in input:iter() do
    local text = cand.text or ""
    if text:sub(1, 1) == MARK then
      -- 释义行：配给上一个还没释义的单词，自己消失
      local meaning = strip_mark(text)
      if pending then
        apply_comment(pending, meaning)
        yield(pending)
        pending = nil
      else
        dropped = dropped or meaning     -- 孤立的释义（没有对应的单词行）
      end
    elseif text:match(WORD_RE) then
      if text == input_text then seen_exact = true end
      if pending then
        yield(pending)          -- 上一个词没有释义（只有原词行）
      end
      pending = cand
    else
      -- 标点 / Typst 片段等：原样放行，不参与释义配对
      if pending then
        yield(pending)
        pending = nil
      end
      yield(cand)
    end
  end
  if pending then
    yield(pending)
  end

  -- 词库里完全没有这个词 → 补一个单词候选，保证空格上屏的是单词
  -- （释义可能来自 AI 词库 / 桥的返回；没有释义也照样给一个词，方便直接上屏）
  if not seen_exact and input_text:match(WORD_RE) then
    local meaning = meaning_for(env, input_text) or dropped
    local seg = back_segment(ctx)
    -- 注意：Candidate() 的第 5 个参数必须是字符串，传 nil 会让 librime-lua
    -- 报 "bad argument #6 (string expected, got nil)" 并且这条候选消失
    local cand = Candidate("en_ai", seg and seg.start or 0,
                           seg and seg._end or #input_text, input_text, meaning or "")
    cand.quality = 0.05
    if meaning then
      apply_comment(cand, meaning)
    end
    yield(cand)
  end
end

return M
