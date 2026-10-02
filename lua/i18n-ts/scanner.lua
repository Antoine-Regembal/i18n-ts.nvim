local M = {}

--- Compiles call names into Lua patterns capturing: call start, quote, key start, key, key end.
function M.compile(functions, patterns)
  local compiled = {}
  for _, name in ipairs(functions) do
    table.insert(compiled, {
      builtin = true,
      pattern = "()" .. vim.pesc(name) .. "%s*%(%s*(['\"])()(.-)()%2",
    })
  end
  for _, pattern in ipairs(patterns or {}) do
    table.insert(compiled, { builtin = false, pattern = pattern })
  end
  return compiled
end

local function is_ident_char(c)
  return c ~= "" and c:match("[%w_$]") ~= nil
end

--- Finds translation calls in `lines`; positions are 0-based, `lnum` offset by `first`.
---@return { lnum: integer, col: integer, end_col: integer, call_end: integer, key: string }[]
function M.scan(lines, compiled, first)
  first = first or 0
  local hits = {}
  for i, line in ipairs(lines) do
    local lnum = first + i - 1
    local taken = {}
    for _, c in ipairs(compiled) do
      local init = 1
      while true do
        if c.builtin then
          local s, e, call_start, _, key_start, key, key_end = line:find(c.pattern, init)
          if not s then
            break
          end
          init = e + 1
          if not is_ident_char(line:sub(call_start - 1, call_start - 1)) and key ~= "" and not taken[key_start] then
            taken[key_start] = true
            table.insert(hits, {
              lnum = lnum,
              col = key_start - 1,
              end_col = key_end - 1,
              call_end = e,
              key = key,
            })
          end
        else
          local s, e, key = line:find(c.pattern, init)
          if not s or not key then
            break
          end
          init = e + 1
          local ks = line:find(key, s, true)
          if ks and not taken[ks] then
            taken[ks] = true
            table.insert(hits, { lnum = lnum, col = ks - 1, end_col = ks - 1 + #key, call_end = e, key = key })
          end
        end
      end
    end
  end
  table.sort(hits, function(a, b)
    return a.lnum == b.lnum and a.col < b.col or a.lnum < b.lnum
  end)
  return hits
end

--- Key currently being typed inside a translation call, for completion.
---@return { start: integer, prefix: string }|nil start is the 0-based column of the key
function M.context(before_cursor, functions)
  for _, name in ipairs(functions) do
    local s, _, call_start, key_start, prefix =
      before_cursor:find("()" .. vim.pesc(name) .. "%s*%(%s*['\"]()([^'\"]*)$")
    if s and not is_ident_char(before_cursor:sub(call_start - 1, call_start - 1)) then
      return { start = key_start - 1, prefix = prefix }
    end
  end
end

return M
