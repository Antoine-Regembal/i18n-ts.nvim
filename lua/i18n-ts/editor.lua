local edit = require("i18n-ts.edit")
local translate = require("i18n-ts.translate")

local M = {}

local ns = vim.api.nvim_create_namespace("i18n-ts.editor")
---@type table<integer, { project: table, key: string, locales: string[], win: integer|nil, busy: boolean }>
local sessions = {}

local function notify(msg, level)
  vim.notify("i18n-ts: " .. msg, level or vim.log.levels.INFO)
end

local function to_line(value)
  return value and (value:gsub("\n", "\\n")) or ""
end

local function from_line(line)
  return (line:gsub("\\n", "\n"))
end

local function decorate(buf)
  local s = sessions[buf]
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local width = 0
  for _, l in ipairs(s.locales) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  for i, l in ipairs(s.locales) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      virt_text = { { l .. string.rep(" ", width - vim.fn.strdisplaywidth(l)) .. " │ ", "I18nTsLocale" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
    if not s.project.store:get(s.key, l) then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { "missing", "I18nTsMissing" } },
        virt_text_pos = "eol",
      })
    end
  end
end

local function set_title(buf, suffix)
  local s = sessions[buf]
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_set_config(s.win, { title = (" %s%s "):format(s.key, suffix or "") })
  end
end

local function finish(s, written, errors, label)
  local fmt = s.project.cfg.add.format_cmd
  if fmt and #written > 0 then
    vim.system(vim.list_extend(vim.deepcopy(fmt), written), { cwd = s.project.root }):wait()
    for _, path in ipairs(written) do
      s.project.store:reload_path(path)
    end
  end
  require("i18n-ts").refresh_project(s.project)
  local msg = ("%s '%s' in %d file(s)"):format(label, s.key, #written)
  for locale, err in pairs(errors) do
    msg = msg .. ("\n%s: %s"):format(locale, err)
  end
  if #written > 0 or next(errors) then
    notify(msg, next(errors) and vim.log.levels.WARN or vim.log.levels.INFO)
  end
end

local function refill(buf)
  local s = sessions[buf]
  if not s or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = {}
  for _, l in ipairs(s.locales) do
    table.insert(lines, to_line(s.project.store:get(s.key, l)))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  decorate(buf)
end

--- Machine-translates the locales still empty after a write, from the default locale.
local function translate_missing(buf)
  local s = sessions[buf]
  local tcfg = s.project.cfg.translate
  local store = s.project.store
  if not tcfg.provider or not tcfg.auto then
    return
  end
  local source = store:get(s.key, store.default_locale)
  local targets = {}
  for _, l in ipairs(s.locales) do
    if l ~= store.default_locale and not store:get(s.key, l) then
      table.insert(targets, l)
    end
  end
  if #targets == 0 then
    return
  end
  if not source then
    return notify(("fill in %s first to translate the other locales"):format(store.default_locale))
  end
  s.busy = true
  set_title(buf, " · translating…")
  M.translate_key(s.project, s.key, targets, function()
    s.busy = false
    set_title(buf)
    refill(buf)
  end)
end

--- Fills `targets` (default: every missing locale) of `key` with machine translations of the default locale.
function M.translate_key(project, key, targets, on_done)
  local store = project.store
  local tcfg = project.cfg.translate
  local source = store:get(key, store.default_locale)
  if not tcfg.provider then
    return notify("set translate.provider to enable machine translation", vim.log.levels.WARN)
  end
  if not source then
    return notify(("'%s' has no %s value to translate from"):format(key, store.default_locale), vim.log.levels.WARN)
  end
  if not targets then
    targets = {}
    for _, l in ipairs(store.locales) do
      if l ~= store.default_locale and not store:get(key, l) then
        table.insert(targets, l)
      end
    end
  end
  if #targets == 0 then
    return notify(("'%s' is translated in every locale"):format(key))
  end
  local req = { key = key, source_locale = store.default_locale, source = source, targets = targets }
  translate.run(tcfg, req, function(err, result, locale_errors)
    local written, errors = {}, vim.deepcopy(locale_errors)
    if err then
      errors[translate.label(tcfg)] = err
    else
      written, errors = edit.set(store, key, result)
      errors = vim.tbl_extend("keep", errors, locale_errors)
    end
    finish({ project = project, key = key }, written, errors, ("machine-translated (%s)"):format(translate.label(tcfg)))
    if on_done then
      on_done()
    end
  end)
end

local function write(buf)
  local s = sessions[buf]
  if s.busy then
    vim.wait(30000, function()
      return not s.busy
    end, 50)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines ~= #s.locales then
    error(("i18n-ts: keep one line per locale (%d expected, %d found)"):format(#s.locales, #lines), 0)
  end
  local values = {}
  for i, l in ipairs(s.locales) do
    values[l] = from_line(lines[i])
  end
  local written, errors = edit.set(s.project.store, s.key, values)
  finish(s, written, errors, "saved")
  refill(buf)
  translate_missing(buf)
end

function M.close(buf)
  local s = sessions[buf]
  if s and s.win and vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_close(s.win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  sessions[buf] = nil
end

function M.locales(buf)
  return sessions[buf] and sessions[buf].locales
end

--- Opens the editor float for `key`; returns the buffer.
function M.open(project, key)
  local store = project.store
  for _, l in ipairs(store.locales) do
    store:ensure(l)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  sessions[buf] = { project = project, key = key, locales = vim.deepcopy(store.locales), busy = false }
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, ("translations://edit/%s/%d"):format(key, buf))
  refill(buf)

  local label, longest = 0, 30
  for _, l in ipairs(store.locales) do
    label = math.max(label, #l)
    longest = math.max(longest, vim.fn.strdisplaywidth(to_line(store:get(key, l))))
  end
  local width = math.min(math.max(label + 3 + longest + 10, 50), vim.o.columns - 4)
  local height = math.min(#store.locales, vim.o.lines - 6)
  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = (" %s "):format(key),
    title_pos = "center",
  }
  if vim.fn.has("nvim-0.10") == 1 then
    win_opts.footer = " :w save · <CR> save & close · q cancel "
    win_opts.footer_pos = "center"
  end
  local win = vim.api.nvim_open_win(buf, true, win_opts)
  sessions[buf].win = win
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      write(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      sessions[buf] = nil
    end,
  })
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map("q", function()
    M.close(buf)
  end)
  map("<Esc>", function()
    M.close(buf)
  end)
  map("<CR>", function()
    vim.cmd("write")
    M.close(buf)
  end)
  return buf
end

return M
