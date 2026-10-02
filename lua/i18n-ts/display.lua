local scanner = require("i18n-ts.scanner")

local M = {}

M.ns = vim.api.nvim_create_namespace("i18n-ts")
M.diag_ns = vim.api.nvim_create_namespace("i18n-ts.diagnostics")

function M.format(value, max_len)
  local text = value:gsub("\r?\n", "⏎")
  if max_len and max_len > 0 and vim.fn.strchars(text) > max_len then
    text = vim.fn.strcharpart(text, 0, max_len - 1) .. "…"
  end
  return text
end

local function visible_range(buf)
  local first, last = math.huge, -1
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    first = math.min(first, vim.fn.line("w0", win))
    last = math.max(last, vim.fn.line("w$", win))
  end
  if last < 0 then
    return nil
  end
  return first - 1, last
end

--- Draws translations for the visible lines of `buf` only.
function M.render(buf, project)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local cfg = project.cfg
  if not project.enabled or cfg.display.mode == "off" then
    return
  end
  local first, last = visible_range(buf)
  if not first then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
  local locale = project.locale
  local inline = cfg.display.mode == "inline"
  for _, hit in ipairs(scanner.scan(lines, project.compiled, first)) do
    local value = project.store:get(hit.key, locale)
    if value then
      vim.api.nvim_buf_set_extmark(buf, M.ns, hit.lnum, inline and hit.call_end or hit.col, {
        virt_text = { { cfg.display.prefix .. M.format(value, cfg.display.max_len), "I18nTsTranslation" } },
        virt_text_pos = inline and "inline" or "eol",
        hl_mode = "combine",
        priority = 120,
      })
    end
  end
end

function M.diagnose(buf, project)
  local cfg = project.cfg.diagnostics
  if not project.enabled or not cfg.enabled then
    vim.diagnostic.reset(M.diag_ns, buf)
    return
  end
  local store = project.store
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local items = {}
  for _, hit in ipairs(scanner.scan(lines, project.compiled, 0)) do
    local base = {
      lnum = hit.lnum,
      col = hit.col,
      end_col = hit.end_col,
      source = "i18n-ts",
      code = hit.key,
    }
    if not store:get(hit.key, store.default_locale) then
      table.insert(
        items,
        vim.tbl_extend("force", base, {
          severity = cfg.severity,
          message = ("Missing translation: %s (%s)"):format(hit.key, store.default_locale),
        })
      )
    elseif cfg.all_locales then
      local missing = {}
      for _, l in ipairs(store.locales) do
        if l ~= store.default_locale and not store:get(hit.key, l) then
          table.insert(missing, l)
        end
      end
      if #missing > 0 then
        table.insert(
          items,
          vim.tbl_extend("force", base, {
            severity = vim.diagnostic.severity.HINT,
            message = ("Missing in %s: %s"):format(table.concat(missing, ", "), hit.key),
          })
        )
      end
    end
  end
  vim.diagnostic.set(M.diag_ns, buf, items)
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    vim.diagnostic.reset(M.diag_ns, buf)
  end
end

return M
