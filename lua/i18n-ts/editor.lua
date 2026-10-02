local edit = require("i18n-ts.edit")
local translate = require("i18n-ts.translate")
local display = require("i18n-ts.display")

local M = {}

local ns = vim.api.nvim_create_namespace("i18n-ts.editor")
---@type table<integer, { project: table, key: string, locales: string[], win: integer|nil }>
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
    local job = (s.project.pending or {})[s.key]
    if job and vim.tbl_contains(job.targets, l) then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { display.spinner[display.frame] .. " translating…", "I18nTsPending" } },
        virt_text_pos = "eol",
      })
    elseif not s.project.store:get(s.key, l) then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { "missing", "I18nTsMissing" } },
        virt_text_pos = "eol",
      })
    end
  end
end

local function set_title(buf)
  local s = sessions[buf]
  if not (s.win and vim.api.nvim_win_is_valid(s.win)) then
    return
  end
  local title = { { (" %s "):format(s.key), "FloatTitle" } }
  local job = (s.project.pending or {})[s.key]
  if job then
    local n = #job.targets
    table.insert(title, {
      ("· %s translating %d locale%s "):format(display.spinner[display.frame], n, n > 1 and "s" or ""),
      "I18nTsPending",
    })
  end
  vim.api.nvim_win_set_config(s.win, { title = title, title_pos = "center" })
end

--- Redraws the loaders of the open floats; called on every spinner frame.
function M.tick()
  for buf, s in pairs(sessions) do
    if vim.api.nvim_buf_is_valid(buf) and (s.project.pending or {})[s.key] then
      decorate(buf)
      set_title(buf)
    end
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
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modified = false
  decorate(buf)
end

local function missing_locales(store, key)
  local targets = {}
  for _, l in ipairs(store.locales) do
    if l ~= store.default_locale and not store:get(key, l) then
      table.insert(targets, l)
    end
  end
  return targets
end

--- Puts freshly translated values into the open floats for `key`, on lines still empty only.
local function show_in_floats(project, key)
  for buf, s in pairs(sessions) do
    if s.project == project and s.key == key and vim.api.nvim_buf_is_valid(buf) then
      local modified = vim.bo[buf].modified
      for i, l in ipairs(s.locales) do
        local value = project.store:get(key, l)
        local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if value and line == "" then
          vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { to_line(value) })
        end
      end
      vim.bo[buf].modified = modified
      decorate(buf)
      set_title(buf)
    end
  end
end

--- Fills `targets` (default: every missing locale) of `key` with machine translations of the default locale,
--- in the background: closing the float doesn't stop it, and values typed meanwhile are kept.
function M.translate_key(project, key, targets, on_done)
  local store = project.store
  local tcfg = project.cfg.translate
  local source = store:get(key, store.default_locale)
  project.pending = project.pending or {}
  if not tcfg.provider then
    return notify("set translate.provider to enable machine translation", vim.log.levels.WARN)
  end
  if not source then
    return notify(("'%s' has no %s value to translate from"):format(key, store.default_locale), vim.log.levels.WARN)
  end
  if project.pending[key] then
    return notify(("'%s' is already being translated"):format(key))
  end
  targets = targets or missing_locales(store, key)
  if #targets == 0 then
    return notify(("'%s' is translated in every locale"):format(key))
  end
  project.pending[key] = { targets = targets, started = vim.uv.now() }
  require("i18n-ts").track_pending(project)
  local req = { key = key, source_locale = store.default_locale, source = source, targets = targets }
  translate.run(tcfg, req, function(err, result, locale_errors)
    project.pending[key] = nil
    local written, errors = {}, vim.deepcopy(locale_errors)
    if err then
      errors[translate.label(tcfg)] = err
    else
      local still_missing = {}
      for _, l in ipairs(missing_locales(store, key)) do
        still_missing[l] = result[l]
      end
      written, errors = edit.set(store, key, still_missing)
      errors = vim.tbl_extend("keep", errors, locale_errors)
    end
    finish({ project = project, key = key }, written, errors, ("machine-translated (%s)"):format(translate.label(tcfg)))
    show_in_floats(project, key)
    if on_done then
      on_done()
    end
  end)
end

--- Machine-translates the locales still empty after a write, from the default locale.
local function translate_missing(buf)
  local s = sessions[buf]
  local tcfg = s.project.cfg.translate
  local store = s.project.store
  if not tcfg.provider or not tcfg.auto or (s.project.pending or {})[s.key] then
    return
  end
  local targets = missing_locales(store, s.key)
  if #targets == 0 then
    return
  end
  if not store:get(s.key, store.default_locale) then
    return notify(("fill in %s first to translate the other locales"):format(store.default_locale))
  end
  M.translate_key(s.project, s.key, targets)
  if vim.api.nvim_buf_is_valid(buf) then
    decorate(buf)
    set_title(buf)
  end
end

local function write(buf)
  local s = sessions[buf]
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

--- Keeps exactly one line per locale: any change that adds or removes lines is rolled back to the last valid state.
local function check_structure(buf)
  local s = sessions[buf]
  if not s or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  s.pending = false
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == #s.locales then
    s.snapshot = lines
    return
  end
  local win = s.win and vim.api.nvim_win_is_valid(s.win) and s.win
  local row = win and vim.api.nvim_win_get_cursor(win)[1] or 1
  -- Outside insert mode, undo drops the change from history, so `u` still reaches earlier edits.
  if not vim.fn.mode():match("^[iR]") then
    vim.api.nvim_buf_call(buf, function()
      pcall(vim.cmd, "silent undo")
    end)
  end
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), s.snapshot) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, s.snapshot)
  end
  decorate(buf)
  if win then
    row = math.min(math.max(row, 1), #s.locales)
    vim.api.nvim_win_set_cursor(win, { row, #s.snapshot[row] })
  end
end

local function guard(buf)
  local s = sessions[buf]
  s.snapshot = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not sessions[buf] then
        return true
      end
      if not s.pending then
        s.pending = true
        vim.schedule(function()
          check_structure(buf)
        end)
      end
    end,
  })
end

local function move(buf, delta)
  local s = sessions[buf]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  row = (row - 1 + delta) % #s.locales + 1
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { row, vim.fn.mode() == "i" and #line or 0 })
end

local function clear_line(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.fn.setreg(vim.v.register, vim.api.nvim_get_current_line())
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, #vim.api.nvim_get_current_line(), { "" })
end

--- Opens the editor float for `key`; returns the buffer.
function M.open(project, key)
  local store = project.store
  for _, l in ipairs(store.locales) do
    store:ensure(l)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  sessions[buf] = { project = project, key = key, locales = vim.deepcopy(store.locales) }
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
    win_opts.footer = " :w save · <CR> save & close · <Tab> next · q cancel "
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
  guard(buf)
  local map = function(lhs, fn, modes)
    vim.keymap.set(modes or "n", lhs, fn, { buffer = buf, nowait = true })
  end
  local noop = function() end
  for _, lhs in ipairs({ "o", "O", "J", "gJ" }) do
    map(lhs, noop)
  end
  map("dd", function()
    clear_line(buf)
  end)
  map("<Tab>", function()
    move(buf, 1)
  end, { "n", "i" })
  map("<S-Tab>", function()
    move(buf, -1)
  end, { "n", "i" })
  map("<CR>", function()
    move(buf, 1)
  end, "i")
  local function at_start(key)
    return function()
      return vim.api.nvim_win_get_cursor(0)[2] == 0 and "" or vim.keycode(key)
    end
  end
  for _, key in ipairs({ "<BS>", "<C-h>", "<C-w>", "<C-u>" }) do
    vim.keymap.set("i", key, at_start(key), { buffer = buf, expr = true, replace_keycodes = false })
  end
  vim.keymap.set("i", "<Del>", function()
    return vim.api.nvim_win_get_cursor(0)[2] >= #vim.api.nvim_get_current_line() and "" or vim.keycode("<Del>")
  end, { buffer = buf, expr = true, replace_keycodes = false })
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
