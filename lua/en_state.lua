-- lua/en_state.lua           【英文模式】共享的内存状态
--
-- 目的：让"每次按键"这条路径上**不做任何文件 I/O**。
-- 滚动偏移、完整释义这些都放内存里，由需要它的组件通过 require 共享
-- （同一个 lua_State，天然共享一份），不再写 cands.tsv / scroll.txt 那种
-- 同步阻塞的小文件。
--
-- 存的东西：
--   offset[word]  滚动偏移（长释义往左滚）
--   meaning[word] 当前候选里该词的完整释义（Ctrl+Enter 上屏用）
--   resp_word / resp_text  桥刚返回的 AI 译文

local M = {}

M.offset = {}          -- word -> 偏移量
M.meaning = {}         -- word -> 完整释义
M.resp_word = nil      -- 桥返回的单词
M.resp_text = nil      -- 桥返回的译文

-- 取该词当前的偏移；换词就从头开始
function M.offset_of(word)
  if word == nil or word == "" then return 0 end
  if M.offset_word ~= word then
    M.offset_word = word
    M.offset[word] = 0
  end
  return M.offset[word] or 0
end

-- 滚动一格，返回新的偏移
function M.bump(word, step)
  local off = M.offset_of(word) + (step or 1)
  M.offset[word] = off
  return off
end

-- 记下候选词 → 完整释义（供 Ctrl+Enter 取用）
function M.set_meaning(word, text)
  if word and word ~= "" then
    M.meaning[word] = text
  end
end

function M.get_meaning(word)
  if not word then return nil end
  return M.meaning[word]
end

function M.clear_meanings()
  M.meaning = {}
end

return M
