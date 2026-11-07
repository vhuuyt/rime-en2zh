-- lua/en_assoc.lua           【英文模式】filter（filters 第一位）
--
-- 把候选改造成"单词 + 尾部释义"：
--   * 释义候选丢掉，改贴到单词候选的 comment 上
--   * 释义超过 en_ai/width 就按窗口滚动（偏移写在 scroll.txt，Tab 由 processor 处理）
--   * 词库（含 AI 补录）里都没有的词，补一个单词候选出来，保证空格上屏的是单词
--   * 同时写 cands.tsv（候选 → 完整释义），给 Ctrl+Enter 用
--
-- 挂载：english.schema.yaml → engine/filters 的 lua_filter@*en_assoc

local M = {}

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

local function split_tabs(line)
  local cols = {}
  for c in (line .. "\t"):gmatch("([^\t]*)\t") do cols[#cols + 1] = c end
  return cols
end

local function char_at(s, i)
  local a = utf8.offset(s, i)
  if not a then return " " end
  local b = utf8.offset(s, i + 1)
  return s:sub(a, (b or (#s + 1)) - 1)
end

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

-- 滚动状态放在文件里，让 en_ai_request（processor）按 Tab 时也能改：
--   <dir>/scroll.txt  第一行 = 偏移量，第二行 = 这条偏移对应的输入
local function read_scroll(env)
  local f = io.open(env.scroll_file, "r")
  if not f then return 0, "" end
  local offset = tonumber(f:read("*l") or "") or 0
  local input = f:read("*l") or ""
  f:close()
  return offset, input
end

local function write_scroll(env, offset, input)
  local f = io.open(env.scroll_file, "w")
  if f then
    f:write(tostring(offset), "\n", input or "", "\n")
    f:close()
  end
end

-- 记录"候选词 -> 完整释义"，供 Ctrl+Enter 把释义上屏用
local function write_cands(env, items)
  local f = io.open(env.cands_file, "w")
  if not f then return end
  f:write(tostring(os.time()), "\n")
  for _, item in ipairs(items) do
    local meaning = item.meaning
    if not meaning then
      local slot = env.words[item.text]
      meaning = slot and slot.meaning
    end
    if meaning and meaning ~= item.text then
      f:write(item.text, "\t", meaning, "\n")
    end
  end
  f:close()
end

local function touch_marquee(env)
  local f = io.open(env.marquee_flag, "w")
  if f then
    f:write(tostring(os.time()))
    f:close()
  end
end

-- dict.yaml -> { coding -> { meaning = 第一条释义, word = 是否有原词行 } }
local function load_dict(path, into, ver_out)
  local f = io.open(path, "r")
  if not f then return end
  local ver
  for line in f:lines() do
    local v = line:match("^#v(%d+)")
    if v then ver = v end
    if line:sub(1, 1) ~= "#" and line:find("\t", 1, true) then
      local cols = split_tabs(line)
      if #cols >= 3 and cols[1] ~= "" and cols[2] ~= "" then
        local code = cols[2]
        local slot = into[code]
        if not slot then
          slot = {}
          into[code] = slot
        end
        if cols[1] == code then
          slot.word = true
        elseif slot.meaning == nil then
          slot.meaning = cols[1]
        end
      end
    end
  end
  f:close()
  if ver_out then ver_out[1] = ver end
end

local function refresh(env)
  if env.loaded then
    local ver
    local f = io.open(env.ai_path, "r")
    if f then
      for _ = 1, 8 do
        local line = f:read("*l")
        if not line then break end
        local v = line:match("^#v(%d+)")
        if v then ver = v break end
      end
      f:close()
    end
    if ver == env.ai_ver then return end
  end
  env.words = {}
  load_dict(env.base_path, env.words)
  local ver = {}
  load_dict(env.ai_path, env.words, ver)
  env.ai_ver = ver[1]
  env.loaded = true
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
  env.marquee_flag = env.dir .. "/marquee.txt"
  env.scroll_file = env.dir .. "/scroll.txt"
  env.cands_file = env.dir .. "/cands.tsv"
  env.auto = (cfg_str(cfg, "en_ai/marquee_auto") or "0") ~= "0"
  env.offset = 0
  env.last_input = ""
  env.loaded = false
  env.ai_ver = nil
  env.words = {}
end

function M.func(input, env)
  local ctx = env.engine.context

  refresh(env)

  local input_text = ctx.input or ""
  local offset, scroll_input = read_scroll(env)
  if input_text ~= env.last_input or scroll_input ~= input_text then
    -- 换了词/按了 Tab 之外的变化：从当前偏移继续（Tab 写入的偏移要保留）
    if scroll_input ~= input_text then
      offset = 0
      write_scroll(env, 0, input_text)
    end
    env.last_input = input_text
  end
  env.offset = offset

  -- 先把候选分流：单词留下，释义丢掉（释义拿去当注释）
  local words, seen_exact, dropped_meaning = {}, false, nil
  for cand in input:iter() do
    local text = cand.text or ""
    if text:match(WORD_RE) then
      if text == input_text then seen_exact = true end
      words[#words + 1] = { cand = cand, text = text }
    elseif not dropped_meaning then
      dropped_meaning = text                    -- AI 候选等：留作兜底释义
    end
  end

  -- 词库（含 AI 补录）里都没有这个词时，补一个"单词"候选，保证空格上单词
  if not seen_exact and input_text:match(WORD_RE) then
    local slot = env.words[input_text]
    local meaning = (slot and slot.meaning) or dropped_meaning
    if meaning then
      local seg = back_segment(ctx)
      local cand = Candidate("en_ai", seg and seg.start or 0,
                             seg and seg._end or #input_text, input_text, meaning)
      cand.quality = 0.05
      table.insert(words, 1, { cand = cand, text = input_text, meaning = meaning })
    end
  end

  -- 输出：释义贴到 comment，过长则跑马灯
  local long_comment = false
  for _, item in ipairs(words) do
    local slot = env.words[item.text]
    local meaning = item.meaning or (slot and slot.meaning)
    if meaning and meaning ~= item.text then
      if env.marquee and (utf8.len(meaning) or #meaning) > env.width then
        long_comment = true
        item.cand.comment = scroll(meaning, env.width, env.offset)
      else
        item.cand.comment = meaning
      end
    end
    yield(item.cand)
  end

  write_cands(env, words)

  if long_comment then
    write_scroll(env, env.offset, input_text)
    if env.auto then                      -- 可选：桥注入 F24 自动滚
      env.offset = env.offset + (env.step or 1)
      touch_marquee(env)
    end
  end
end

return M
