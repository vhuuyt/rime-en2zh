-- lua/en_ai_candidate.lua    【英文模式】translator
--
-- 读 <tmp>/rime_en_ai/response.txt（桥刚查完的那一条），命中当前输入就补一条候选；
-- 注释形如 [AI]·minimax（带当前档位）。不联网、不阻塞。
--
-- 挂载：english.schema.yaml → engine/translators 里的 lua_translator@*en_ai_candidate

local M = {}

local function default_dir()
  local tmp = os.getenv("TEMP") or os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
  tmp = tmp:gsub("\\+$", "")
  return tmp .. "/rime_en_ai"
end

local function default_ai_dict()
  local appdata = os.getenv("APPDATA")
  if appdata then
    return appdata:gsub("\\", "/") .. "/Rime/dicts/ai_ecdict.dict.yaml"
  end
  local home = os.getenv("HOME") or "."
  return home .. "/Library/Rime/dicts/ai_ecdict.dict.yaml"
end

local function cfg_str(cfg, key)
  local v = cfg:get_string(key)
  if v == nil or v == "" then return nil end
  return v
end

local function split_tabs(line)
  local cols = {}
  for c in (line .. "\t"):gmatch("([^\t]*)\t") do
    cols[#cols + 1] = c
  end
  return cols
end

-- 解析 ai_ecdict.dict.yaml：code -> 释义（挑第一条 text ~= code 的）
local function refresh_ai_dict(env)
  local f = io.open(env.ai_dict, "r")
  if not f then
    if env.ai_ver ~= "" then
      env.ai, env.ai_ver = {}, ""
    end
    return
  end
  local head = {}
  local ver = nil
  -- 头部几行里找版本标记
  for _ = 1, 8 do
    local line = f:read("*l")
    if not line then break end
    head[#head + 1] = line
    local v = line:match("^#v(%d+)")
    if v then ver = v end
  end
  if ver == env.ai_ver then
    f:close()
    return
  end
  local words = {}
  for _, line in ipairs(head) do
    local cols = split_tabs(line)
    if #cols >= 3 and cols[1] ~= "" and cols[1] ~= cols[2] then
      words[cols[2]] = words[cols[2]] or cols[1]
    end
  end
  for line in f:lines() do
    local cols = split_tabs(line)
    if #cols >= 3 and cols[1] ~= "" and cols[1] ~= cols[2] then
      words[cols[2]] = words[cols[2]] or cols[1]
    end
  end
  f:close()
  env.ai, env.ai_ver = words, ver or "0"
end

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

function M.init(env)
  local cfg = env.engine.schema.config
  env.dir = default_dir()
  local dir = cfg_str(cfg, "en_ai/dir")
  if dir then env.dir = dir:gsub("\\", "/"):gsub("/+$", "") end
  env.marker = cfg_str(cfg, "en_ai/marker") or "[AI]"
  env.profile_file = env.dir .. "/ai_profile.txt"
  env.ai_dict = cfg_str(cfg, "en_ai/ai_dict") or default_ai_dict()
  env.ai_ver = nil
  env.ai = {}
  env.cache = {}
end

function M.func(input, seg, env)
  if input == nil or input == "" then return end
  local ctx = env.engine.context
  if not ctx:get_option("ai_translate") then return end

  refresh_ai_dict(env)

  local text = env.ai[input]
  if not text then
    text = env.cache[input]
    if not text then
      local word, got = read_response(env.dir)
      if word == input and got and got ~= "" then
        text = got
        env.cache[input] = got
      end
    end
  end
  if not text then return end

  -- 注释里带上当前 AI 档位，切换时立刻能看出来
  local marker = env.marker
  local f = io.open(env.profile_file, "r")
  if f then
    local name = (f:read("*l") or ""):gsub("%s+$", "")
    f:close()
    if name ~= "" then marker = env.marker .. "·" .. name end
  end

  local cand = Candidate("en_ai", seg.start, seg._end, text, marker)
  cand.quality = 0.1      -- 本地词典优先，AI 排在后面
  yield(cand)
end

return M
