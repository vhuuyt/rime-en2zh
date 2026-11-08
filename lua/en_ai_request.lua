-- lua/en_ai_request.lua      【英文模式】processor（排在 processors 第一位）
--
-- 只在按键上做决定，**打字过程中不写任何文件**（英文模式的手感全靠这条）：
--   Tab          → 三选一，见下面 func 里的注释（滚长释义 / 放行 / 发 AI 请求）
--   Ctrl+Enter   → 把当前高亮候选的释义上屏（完整释义在 en_state 内存里）
--   Ctrl+Delete  → 删掉这个 AI 补录的词（只删 ai_ecdict.dict.yaml），删完收起候选框
--   F24          → 桥注入的假按键，只用来触发候选重绘
--   档位变化      → 把 F4 选单里选中的 AI 档位写进 ai_profile.txt（仅变化时写一次）
--
-- AI 有两条触发路径，都只是写一次 request.txt，剩下的（计时/联网/写回）交给桥：
--   1. 打字时自动：每次输入变化写一条（第 2 行 = en_ai/delay_ms），桥发现这个内容
--      900ms 没再变 → 才发请求。所以"停手一会儿就自动出 AI 释义"。
--   2. 按 Tab 立刻：第 2 行写 0，桥立即发（本地查不到这个词时才有意义）。
-- 关掉自动触发（变成只能按 Tab）：en_ai/auto: 0。
--
-- 挂载：english.schema.yaml → engine/processors 第一项 lua_processor@*en_ai_request

local M = {}

-- 内存状态（滚动偏移、完整释义）：与 filter 共享，避免每次按键读写文件
local state = require("en_state")

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
  env.min_len = tonumber(cfg_str(cfg, "en_ai/min_input_len") or "") or 2
  env.auto = (cfg_str(cfg, "en_ai/auto") or "1") ~= "0"
  env.delay_ms = tonumber(cfg_str(cfg, "en_ai/delay_ms") or "") or 900
  env.tab_key = cfg_str(cfg, "en_ai/tab") or "Tab"
  env.tab_step = tonumber(cfg_str(cfg, "en_ai/tab_step") or "") or 4
  env.width = tonumber(cfg_str(cfg, "en_ai/width") or "") or 20
  env.marquee_auto = (cfg_str(cfg, "en_ai/marquee_auto") or "0") ~= "0"
  env.last_profile = nil
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
  local appdata = os.getenv("APPDATA")
  local rime_dir = appdata and (appdata:gsub("\\", "/") .. "/Rime")
                    or ((os.getenv("HOME") or ".") .. "/Library/Rime")
  env.ai_dict = cfg_str(cfg, "en_ai/ai_dict") or (rime_dir .. "/dicts/ai_ecdict.dict.yaml")

  env.last_input = ""
  env.last_requested = nil        -- 上一次写进 request.txt 的词（去重，别重复写同一个）
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
  if env.last_profile == name then return end   -- 没变 → 不碰文件
  env.last_profile = name
  local out = io.open(env.profile_file, "w")
  if out then
    out:write(name, "\n")
    out:close()
  end
end

-- 请求文件格式：第 1 行 = 单词，第 2 行 = 停顿毫秒（Tab 触发固定 0 = 立刻），第 3 行 = 时间戳
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

-- processor 在按键**进入组合之前**运行，所以 ctx.input 还是上一帧的值。
-- 想按"这一下按键之后的词"去请求，就得自己推算一下；否则请求文件里永远是
-- 少一个字母的词（桥会照着错的词查，甚至把截断的词写进 AI 词库）。
local function predict_input(cur, repr)
  local ch = repr:match("^([A-Za-z])$") or repr:match("^Shift%+([A-Za-z])$")
  if ch then return cur .. ch end
  if repr == "BackSpace" or repr == "Control+BackSpace" then
    return cur:sub(1, -2)
  end
  return nil                      -- 其他键不改输入
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

  -- Ctrl+Enter = 把当前高亮候选的释义上屏（完整释义在 en_state 里，filter 写的）
  if repr == env.commit_key and ctx:is_composing() then
    local cand = ctx:get_selected_candidate()
    local word = cand and cand.text or nil
    local meaning = word and state.get_meaning(word) or nil
    if not meaning and cand then
      local c = cand.comment
      -- "~xxx" 是补全提示（剩余字母），不是释义
      if c and c ~= "" and c:sub(1, 1) ~= "~" then meaning = c end
    end
    if meaning and meaning ~= "" then
      env.engine:commit_text(meaning)
      ctx:clear()
      return 1
    end
  end

  -- Tab 有三个用途，看当前词有没有本地释义：
  --   有长释义       → 往左滚一格（滚动偏移在 en_state 内存里，不写文件）
  --   有释义但不长   → 放行给应用
  --   没有释义       → 触发一次 AI 查询（delay 0，桥立即发）
  if repr == env.tab_key and ctx:is_composing() then
    local cur = ctx.input or ""
    if cur ~= "" then
      -- 1) 有长释义？完整释义在 en_state 里（filter 写的）
      local full = state.get_meaning(cur)
      if full and (utf8.len(full) or #full) > env.width then
        state.bump(cur, env.tab_step)
        ctx:refresh_non_confirmed_composition()
        return 1                     -- 吃掉 Tab，不再传给应用
      end
      -- 2) 本地有释义（短）→ Tab 无事可做，放行
      if state.get_meaning(cur) then
        return 2
      end
      -- 3) 没有释义 → 让桥去问 AI（立刻，不等停顿）
      if #cur >= env.min_len then
        write_request(env.dir, cur, 0)
        return 1
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
    env.last_requested = nil
    return 2
  end
  if not ctx:get_option("ai_translate") then
    return 2
  end

  -- 非字母键（导航/选词/空格）时暂停自动跑马灯，免得重绘冲掉选中项。
  -- 只有开了自动跑马灯（marquee_auto）才需要写这个标记；默认关 → 不写文件。
  if env.marquee_auto then
    local repr_ok = (repr == "F24") or repr:match("^[a-z]$") or repr:match("^Shift%+[A-Z]$")
    if not repr_ok then
      local f = io.open((env.dir or "") .. "/marquee_pause.txt", "w")
      if f then
        f:write(tostring(os.time()))
        f:close()
      end
    end
  end

  -- 自动查词：输入变了就写一条请求（请求文件里带着 delay_ms，桥等它稳定下来才发）。
  -- 每次按键只做一次 ~12 字节的写，且只在"这个词本地没有释义"时才写。
  if env.auto and ctx:is_composing() then
    local cur = ctx.input or ""
    local word = predict_input(cur, repr)
    -- 不要在这里用"前缀已有释义"来跳过：polar 本身是个词，打 pola→polar 之后
    -- 后面每个字母都会被跳过，请求文件就永远停在半截词上（查出来是别的词）。
    -- 认得的词由桥那边判断（skip_local），这边只管如实汇报当前输入。
    if word and #word >= env.min_len and word ~= env.last_requested then
      env.last_requested = word
      write_request(env.dir, word, env.delay_ms)
    end
  end
  return 2
end

return M
