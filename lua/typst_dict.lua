-- lua/typst_dict.lua         【三方案通用】translator
--
-- Typst 片段词典：输入 trigger（默认 typ）后，候选栏列出全部片段；
-- 继续敲字母做前缀过滤，例如 typfig → figure 模板。
--
-- 挂载（schema .custom.yaml，三端一致）：
--   engine/translators:
--     - lua_translator@*typst_dict
--   typst_dict/trigger: typ        # 可选，改触发词
--
-- 说明：
--   * key 只能用 speller/alphabet 允许的字符（这里是小写字母），
--     否则那串输入根本打不出来。
--   * 上屏内容 = Candidate 的 text，可以带 # " [ ] 等任意字符。
--   * cand.quality 调高，保证命中时片段排在同音词前面。

local M = {}

-- key 是 trigger 之后要敲的字母；text 是上屏内容；comment 是候选栏右侧说明
local builtin_entries = {
  { "emph",   "#emph[]",                         "强调" },
  { "emph-line", "#emph-line[]",                 "划线强调" },
  { "figure", '#figure(image(""), width:100% caption: [])', "图片+题注" },
  { "image",  'image("")',                       "图片" },
  { "table",  '#table(columns: (auto, auto), [A], [B])', "表格" },
  { "link",   '#link("")[]',                     "链接" },
  { "block",  "#block[]",                        "块" },
  { "code",   "`code`",                          "行内代码" },
  { "super",  "#super[]",                        "上标" },
  { "sub",    "#sub[]",                          "下标" },
}

function M.init(env)
  -- lua_translator@*typst_dict 时 env.name_space 是 "typst_dict"
  local ns = (env.name_space or ""):gsub("^%*", "")
  env.config_prefix = (ns ~= "" and ns or "typst_dict")
  env.trigger = env.engine.schema.config:get_string(env.config_prefix .. "/trigger")
                or "typ"
  env.entries = builtin_entries
end

local function emit(seg, entry, quality, exact)
  local cand = Candidate("typst", seg.start, seg._end, entry[2], entry[3] or entry[1])
  cand.quality = quality
  if exact then cand.comment = entry[1] .. " · " .. (entry[3] or "") end
  yield(cand)
end

function M.func(input, seg, env)
  local trigger = env.trigger
  if #input < #trigger or input:sub(1, #trigger) ~= trigger then
    return
  end
  local suffix = input:sub(#trigger + 1)

  -- 1) 精确命中优先（typfig 时 figure 一定排第一）
  for _, e in ipairs(env.entries) do
    if e[1] == suffix then
      emit(seg, e, 1000, false)
    end
  end
  -- 2) 前缀命中，按表内顺序展开
  for _, e in ipairs(env.entries) do
    if e[1] ~= suffix and e[1]:sub(1, #suffix) == suffix then
      emit(seg, e, 900, false)
    end
  end
end

return M
