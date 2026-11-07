-- lua/en_dict_data.lua      【英文模式】共享模块
--
-- 把两个词库读进内存，给 en_assoc.lua / en_ai_candidate.lua 共用：
--     dicts/ecdict.dict.yaml      英文基础词库（4 万词）
--     dicts/chem_ecdict.dict.yaml 化学词库（1.6 万）
--     dicts/ai_ecdict.dict.yaml   AI 补录词库（桥自动写）
--
-- 格式是 Rime 词典的「文本<TAB>编码<TAB>权重」：
--     hello            hello      10     ← 原词行
--     interj. 喂；嘿   hello       0     ← 释义行（文本≠编码）
-- 所以 code → 第一条释义。
--
-- 每个词库头部有一行 "#v<时间戳>"，变了就整份重读；
-- 模块缓存在 lua 的 package.loaded 里，多个组件共用一份，不重复占内存。

local M = {}

M.words = nil          -- { code -> { meaning = "...", word = true } }
M.base_path = nil
M.ai_path = nil
M.base_ver = nil
M.ai_ver = nil

local function split_tabs(line)
  local cols = {}
  for c in (line .. "\t"):gmatch("([^\t]*)\t") do
    cols[#cols + 1] = c
  end
  return cols
end

-- 读文件头部的 "#v<时间戳>"
local function file_version(path)
  if not path or path == "" then return "" end
  local f = io.open(path, "r")
  if not f then
    return ""
  end
  local ver = ""
  for _ = 1, 8 do
    local line = f:read("*l")
    if not line then break end
    local v = line:match("^#v(%d+)")
    if v then
      ver = v
      break
    end
  end
  f:close()
  return ver
end

local function load_file(path, into)
  if not path or path == "" then return end
  local f = io.open(path, "r")
  if not f then
    return
  end
  for line in f:lines() do
    if line:sub(1, 1) ~= "#" and line:find("\t", 1, true) then
      local cols = split_tabs(line)
      if #cols >= 2 and cols[1] ~= "" and cols[2] ~= "" then
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
end

-- 取释义：先按原样找，再按小写找（"Info" → "info"）
function M.meaning(words, text)
  if not text or text == "" then
    return nil
  end
  local slot = words[text]
  if slot and slot.meaning then
    return slot.meaning
  end
  local lower = text:lower()
  if lower ~= text then
    slot = words[lower]
    if slot and slot.meaning then
      return slot.meaning
    end
  end
  return nil
end

-- 载入（带缓存；任何词库变了会自动重读）
function M.load(base_path, ai_path)
  local base_ver = file_version(base_path)
  local ai_ver = file_version(ai_path)
  if M.words and base_ver == M.base_ver and ai_ver == M.ai_ver then
    return M.words
  end
  local words = {}
  load_file(base_path, words)
  load_file(ai_path, words)
  M.words = words
  M.base_path, M.ai_path = base_path, ai_path
  M.base_ver, M.ai_ver = base_ver, ai_ver
  return words
end

function M.invalidate()
  M.words = nil
end

return M
