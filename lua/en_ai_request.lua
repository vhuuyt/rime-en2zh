-- lua/en_ai_request.lua      【英文模式】processor（排在 processors 第一位）
--
-- 一次按键里做四件事：
--   1. 拼写中每次输入变化 → 写 <tmp>/rime_en_ai/request.txt（只写文件，绝不联网）
--   2. Tab              → 长释义往前滚（仅当 filter 写了 scroll.txt 且词匹配）
--   3. Ctrl+Enter       → 把当前高亮候选的释义上屏
--   4. Ctrl+Delete      → 删掉这个 AI 补录的词（只删 ai_ecdict.dict.yaml），删完收起候选框
--   另外：收 F24（桥注入的假按键）→ 重绘候选；顺带把方案选单里选中的 AI 档位写进 ai_profile.txt
--
-- 挂载：english.schema.yaml → engine/processors 第一项 lua_processor@*en_ai_request

local M = {}

local function default_dir()
  local tmp = os.getenv("TEMP") or os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
  tmp = tmp:gsub("\\+$", "")
  return tmp .. "/rime_en_ai"
end

-- 目录由 scripts/ai_bridge.py 启动时创建；这里不调用 shell：
-- 在非 Windows 环境里 `2>nul` 会真的生成一个名为 nul 的文件，而用户目录里
-- 出现 nul 会让 librime 部署时 boost::filesystem 抛异常（表现为「部署崩溃」）。
local function cfg_str(cfg, key)
  local v = cfg:get_string(key)
  if v == nil or v == "" then return nil end
  return v
end

function M.init(env)
  local cfg = env.engine.schema.config
  env.dir = default_dir()
  local dir = cfg_str(cfg, "en_ai/dir")
  if dir then env.dir = dir:gsub("\\", "/"):gsub("/+$", "") end
  env.delay_ms = tonumber(cfg_str(cfg, "en_ai/delay_ms") or "") or 900
  env.min_len = tonumber(cfg_str(cfg, "en_ai/min_input_len") or "") or 2
  env.trigger = cfg_str(cfg, "en_ai/trigger") or ""
  env.tab_key = cfg_str(cfg, "en_ai/tab") or "Tab"
  env.tab_step = tonumber(cfg_str(cfg, "en_ai/tab_step") or "") or 4
  env.scroll_file = env.dir .. "/scroll.txt"
  env.cands_file = env.dir .. "/cands.tsv"
  env.commit_key = cfg_str(cfg, "en_ai/commit_key") or "Control+Return"
  env.delete_key = cfg_str(cfg, "en_ai/delete_key") or "Control+Delete"
  env.delete_key_alt = cfg_str(cfg, "en_ai/delete_key_alt") or "Control+BackSpace"
  env.profile_file = env.dir .. "/ai_profile.txt"
  env.profile_option_prefix = cfg_str(cfg, "en_ai/profile_option_prefix") or "ai_"
  env.profiles = {}
  local list = cfg_str(cfg, "en_ai/profiles")
  if list then
    for name in list:gmatch("[^,%s]+") do
      env.profiles[#env.profiles + 1] = name
    end
  end
  env.delete_close = (cfg_str(cfg, "en_ai/delete_close") or "1") ~= "0"
  env.ai_dict = cfg_str(cfg, "en_ai/ai_dict")
  if not env.ai_dict then
    local appdata = os.getenv("APPDATA")
    env.ai_dict = appdata and (appdata:gsub("\\", "/") .. "/Rime/ai_ecdict.dict.yaml")
                     or ((os.getenv("HOME") or ".") .. "/Library/Rime/ai_ecdict.dict.yaml")
  end

  env.last_input = ""
end

-- 当前档位由方案选单里的单选组决定（ai_minimax / ai_openai …），
-- 选中哪个就把它的名字写进 ai_profile.txt，桥下一次请求照此办理。
local function sync_profile(ctx, env)
  if #env.profiles == 0 then return end
  local name
  for _, candidate in ipairs(env.profiles) do
    if ctx:get_option(env.profile_option_prefix .. candidate) then
      name = candidate
      break
    end
  end
  name = name or env.profiles[1]
  local current = ""
  local f = io.open(env.profile_file, "r")
  if f then
    current = (f:read("*l") or ""):gsub("%s+$", "")
    f:close()
  end
  if current == name then return end
  local out = io.open(env.profile_file, "w")
  if out then
    out:write(name, "\n")
    out:close()
  end
end

-- 请求文件格式：第 1 行 = 单词，第 2 行 = 停顿毫秒，第 3 行 = 时间戳
local function split_tabs(line)
  local cols = {}
  for c in (line .. "\t"):gmatch("([^\t]*)\t") do cols[#cols + 1] = c end
  return cols
end

-- 从 ai_ecdict.dict.yaml 里删掉某个词（连同首字母大写版本），并抬高版本号让 filter 重读
local function delete_from_ai_dict(path, word)
  local f = io.open(path, "r")
  if not f then return false end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()

  local cap = word:sub(1, 1):upper() .. word:sub(2)
  local out, removed, has_ver = {}, false, false
  for _, line in ipairs(lines) do
    if line:match("^#v%d+") then
      out[#out + 1] = "#v" .. tostring(os.time())
      has_ver = true
    else
      local cols = split_tabs(line)
      local code = (#cols >= 3) and cols[2] or nil
      if code == word or code == cap then
        removed = true
      else
        out[#out + 1] = line
      end
    end
  end
  if not removed then return false end
  if not has_ver then table.insert(out, 2, "#v" .. tostring(os.time())) end

  local w = io.open(path, "w")
  if not w then return false end
  w:write(table.concat(out, "\n"), "\n")
  w:close()
  return true
end

local function write_request(dir, input, delay_ms)
  local f = io.open(dir .. "/request.txt", "w")
  if not f then return false end
  f:write(input, "\n", tostring(math.floor(delay_ms)), "\n", tostring(os.time()), "\n")
  f:close()
  return true
end

function M.func(key, env)
  local repr = key:repr()
  local ctx = env.engine.context

  -- Ctrl+Delete = 删掉当前高亮候选，但**只删 AI 词库里的词**；
  -- 基库（ECDICT）的词不动，原样放行给应用
  if (repr == env.delete_key or repr == env.delete_key_alt) and ctx:is_composing() then
    local cand = ctx:get_selected_candidate()
    local word = cand and cand.text or nil
    if word and word:match("^[%a][%a'%-]*$") and delete_from_ai_dict(env.ai_dict, word) then
      if env.delete_close then
        ctx:clear()                 -- 直接收起候选框，回到空闲状态（就是"删掉收工"的手感）
      else
        ctx:refresh_non_confirmed_composition()
      end
      return 1
    end
    return 2
  end

  -- Ctrl+Enter = 把当前高亮候选的释义上屏（联想模式下释义只在 comment 里）
  if repr == env.commit_key and ctx:is_composing() then
    local cand = ctx:get_selected_candidate()
    local word = cand and cand.text or nil
    if word then
      local f = io.open(env.cands_file, "r")
      if f then
        f:read("*l")                       -- 第一行是时间戳
        local meaning
        for line in f:lines() do
          local w, m = line:match("^([^\t]*)\t(.+)$")
          if w == word then
            meaning = m
            break
          end
        end
        f:close()
        if meaning and meaning ~= "" then
          env.engine:commit_text(meaning)
          ctx:clear()
          return 1
        end
      end
    end
    -- 没找到释义：继续往下走（可能还配了 en_ai/trigger）
  end

  -- Tab = 把过长的释义往左滚一格（只在联想模式、且当前词确实有长释义时生效）
  if repr == env.tab_key and ctx:is_composing() then
    local f = io.open(env.scroll_file, "r")
    if f then
      local offset = tonumber(f:read("*l") or "") or 0
      local input = f:read("*l") or ""
      f:close()
      if input == (ctx.input or "") and input ~= "" then
        local out = io.open(env.scroll_file, "w")
        if out then
          out:write(tostring(offset + env.tab_step), "\n", input, "\n")
          out:close()
        end
        ctx:refresh_non_confirmed_composition()
        return 1                     -- 吃掉 Tab，不再传给应用
      end
    end
  end

  -- 桥接脚本注入的假按键：只用来触发候选重绘
  if repr == "F24" then
    if ctx:is_composing() then
      ctx:refresh_non_confirmed_composition()
    end
    return 1
  end

  sync_profile(ctx, env)

  if not ctx:is_composing() then
    env.last_input = ""
    return 2
  end
  if not ctx:get_option("ai_translate") then
    return 2
  end

  -- 非字母键（导航/选词/空格）时暂停跑马灯，免得重绘冲掉选中项
  local repr_ok = false
  if repr == "F24" then
    repr_ok = true
  elseif repr:match("^[a-z]$") or repr:match("^Shift%+[A-Z]$") then
    repr_ok = true
  end
  if not repr_ok then
    local f = io.open((env.dir or "") .. "/marquee_pause.txt", "w")
    if f then
      f:write(tostring(os.time()))
      f:close()
    end
  end

  local input = ctx.input or ""
  if input == env.last_input then
    return 2
  end
  env.last_input = input
  if #input < env.min_len then
    return 2
  end

  if env.trigger ~= "" and repr == env.trigger then
    -- 显式触发：把停顿改成 0，桥接脚本立刻请求
    write_request(env.dir, input, 0)
    return 1
  end

  write_request(env.dir, input, env.delay_ms)
  return 2
end

return M
