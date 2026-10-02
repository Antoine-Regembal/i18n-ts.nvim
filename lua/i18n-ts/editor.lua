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

local function pad(text, width)
  return text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))
end

--- Keymap legend, two entries per row; translation entries only with a provider.
--- Configured keys of an action as a list; empty when disabled.
local function keys_of(project, action)
  local keys = ((project.cfg.editor or require("i18n-ts.config").defaults.editor).keys or {})[action]
  if not keys then
    return {}
  end
  return type(keys) == "table" and keys or { keys }
end

local function legend_items(s)
  local translating = s.project.cfg.translate.provider ~= nil
  local entries = {
    { "save", "save", ":w" },
    { "translate", "translate empty", nil, translating },
    { "save_close", "save & close" },
    { "retranslate", "re-translate all", nil, translating },
    { "next", "next locale" },
    { "clear", "clear value" },
    { "close", "close" },
    { "help", "hide help" },
  }
  local items = {}
  for _, e in ipairs(entries) do
    local key = e[3] or keys_of(s.project, e[1])[1]
    if key and e[4] ~= false then
      table.insert(items, { key, e[2] })
    end
  end
  return items
end

local DESC_WIDTH = 19

local function key_width(items)
  local width = 5
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(item[1]))
  end
  return width + 2
end

--- Width of the two-column legend, for the float size.
local function legend_width(s)
  return 1 + 2 * (key_width(legend_items(s)) + DESC_WIDTH)
end

local function legend_lines(s, width)
  local items = legend_items(s)
  local kw = key_width(items)
  local lines = { { { string.rep("─", width), "FloatBorder" } } }
  for i = 1, #items, 2 do
    local row = { { " " } }
    for j = i, math.min(i + 1, #items) do
      table.insert(row, { pad(items[j][1], kw), "I18nTsKey" })
      table.insert(row, { pad(items[j][2], DESC_WIDTH), "Comment" })
    end
    table.insert(lines, row)
  end
  return lines
end

local function counts(s, buf)
  local missing, modified = 0, 0
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(s.locales) do
    local value = s.project.store:get(s.key, l)
    if not value then
      missing = missing + 1
    end
    if lines[i] and lines[i] ~= "" and lines[i] ~= to_line(value) then
      modified = modified + 1
    end
  end
  return missing, modified
end

local function decorate(buf)
  local s = sessions[buf]
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local store = s.project.store
  local width = 0
  for _, l in ipairs(s.locales) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local job = (s.project.pending or {})[s.key]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(s.locales) do
    local is_source = l == store.default_locale
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      virt_text = {
        { is_source and " ★ " or "   ", "I18nTsSource" },
        { pad(l, width), is_source and "I18nTsSource" or "I18nTsLocale" },
        { " │ ", "FloatBorder" },
      },
      virt_text_pos = "inline",
      right_gravity = false,
    })
    local value = store:get(s.key, l)
    local badges = {}
    local line = lines[i] or ""
    if job and vim.tbl_contains(job.targets, l) then
      table.insert(badges, { display.spinner[display.frame] .. " translating…", "I18nTsPending" })
    elseif line == "" and value then
      table.insert(badges, { "○ emptied, kept on save", "Comment" })
    elseif line == "" then
      table.insert(badges, { "○ missing", "I18nTsMissing" })
    end
    if line ~= "" and line ~= to_line(value) then
      table.insert(badges, { "● modified", "I18nTsModified" })
    end
    if is_source then
      table.insert(badges, { "source", "I18nTsSource" })
    end
    if #badges > 0 then
      local chunks = { { "  " } }
      for b, badge in ipairs(badges) do
        if b > 1 then
          table.insert(chunks, { "  " })
        end
        table.insert(chunks, badge)
      end
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { virt_text = chunks, virt_text_pos = "eol" })
    end
  end
  if s.help and #s.locales > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, #s.locales - 1, 0, {
      virt_lines = legend_lines(s, s.width or 50),
    })
  end
end

local function window_height(s)
  local legend = s.help and (math.ceil(#legend_items(s) / 2) + 1) or 0
  return math.max(math.min(#s.locales + legend, vim.o.lines - 6), 1)
end

--- Title (key and translation progress) and footer (counts and provider) of the float.
local function set_title(buf)
  local s = sessions[buf]
  if not (s.win and vim.api.nvim_win_is_valid(s.win)) then
    return
  end
  local title = { { " i18n ", "I18nTsTitleTag" }, { " " .. s.key .. " ", "FloatTitle" } }
  local job = (s.project.pending or {})[s.key]
  if job then
    local n = #job.targets
    table.insert(title, {
      ("%s translating %d locale%s "):format(display.spinner[display.frame], n, n > 1 and "s" or ""),
      "I18nTsPending",
    })
  end
  local config = { title = title, title_pos = "center" }
  if vim.fn.has("nvim-0.10") == 1 then
    local missing, modified = counts(s, buf)
    local footer = { { " " } }
    local function add(text, hl)
      if #footer > 1 then
        table.insert(footer, { " · ", "FloatBorder" })
      end
      table.insert(footer, { text, hl })
    end
    add(
      missing == 0 and "✓ all locales" or ("%d missing"):format(missing),
      missing == 0 and "I18nTsDone" or "I18nTsMissing"
    )
    if modified > 0 then
      add(("%d modified"):format(modified), "I18nTsModified")
    end
    local tcfg = s.project.cfg.translate
    add(tcfg.provider and translate.label(tcfg) or "translation off", "Comment")
    if not s.help then
      add("? help", "I18nTsKey")
    end
    table.insert(footer, { " " })
    config.footer = footer
    config.footer_pos = "center"
  end
  vim.api.nvim_win_set_config(s.win, config)
end

local function toggle_help(buf)
  local s = sessions[buf]
  s.help = not s.help
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_set_config(s.win, { height = window_height(s) })
  end
  decorate(buf)
  set_title(buf)
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

--- Every locale but the default one: the locale set of the project's translation session.
function M.other_locales(store)
  return vim.tbl_filter(function(l)
    return l ~= store.default_locale
  end, store.locales)
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

--- Puts freshly translated values into the open floats for `key`, on lines still showing the value from before.
local function show_in_floats(project, key, before)
  for buf, s in pairs(sessions) do
    if s.project == project and s.key == key and vim.api.nvim_buf_is_valid(buf) then
      local modified = vim.bo[buf].modified
      for i, l in ipairs(s.locales) do
        local value = project.store:get(key, l)
        local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if value and line ~= to_line(value) and (line == "" or line == to_line(before[l])) then
          vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { to_line(value) })
        end
      end
      vim.bo[buf].modified = modified
      decorate(buf)
      set_title(buf)
    end
  end
end

--- Machine-translates `targets` (default: every missing locale) of `key` from the default locale, in the
--- background: closing the float doesn't stop it. A locale changed while the request runs is left as is.
--- `opts.overwrite` replaces existing values too; otherwise only empty locales are filled.
function M.translate_key(project, key, targets, on_done, opts)
  opts = opts or {}
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
  local before = {}
  for _, l in ipairs(targets) do
    before[l] = store:get(key, l)
  end
  project.pending[key] = { targets = targets, started = vim.uv.now() }
  require("i18n-ts").track_pending(project)
  local req = {
    key = key,
    source_locale = store.default_locale,
    source = source,
    targets = targets,
    schema_locales = M.other_locales(store),
  }
  translate.run(tcfg, req, function(err, result, locale_errors)
    project.pending[key] = nil
    local written, errors = {}, vim.deepcopy(locale_errors)
    if err then
      errors[translate.label(tcfg)] = err
    else
      local apply = {}
      for _, l in ipairs(targets) do
        local current = store:get(key, l)
        if current == before[l] and (opts.overwrite or current == nil) then
          apply[l] = result[l]
        end
      end
      written, errors = edit.set(store, key, apply)
      errors = vim.tbl_extend("keep", errors, locale_errors)
    end
    finish({ project = project, key = key }, written, errors, ("machine-translated (%s)"):format(translate.label(tcfg)))
    show_in_floats(project, key, before)
    if on_done then
      on_done()
    end
  end)
end

--- Machine-translates the saved locales still empty, from the saved default locale value.
---@param opts { quiet: boolean } quiet: no notice when there is nothing to do (closing the float)
local function translate_missing(project, key, buf, opts)
  local tcfg = project.cfg.translate
  local store = project.store
  if not tcfg.provider or (project.pending or {})[key] then
    return
  end
  local targets = missing_locales(store, key)
  if #targets == 0 then
    return opts.quiet or notify(("'%s' is translated in every locale"):format(key))
  end
  if not store:get(key, store.default_locale) then
    return opts.quiet or notify(("fill in %s first to translate the other locales"):format(store.default_locale))
  end
  M.translate_key(project, key, targets)
  if buf and vim.api.nvim_buf_is_valid(buf) and sessions[buf] then
    decorate(buf)
    set_title(buf)
  end
end

--- Saves the float, then translates its empty locales right away.
function M.translate_now(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  if not s.project.cfg.translate.provider then
    return notify("set translate.provider to enable machine translation", vim.log.levels.WARN)
  end
  if vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
  end
  translate_missing(s.project, s.key, buf, { quiet = false })
end

--- Re-translates every locale of `key` from the default one, replacing existing values, after confirmation.
function M.retranslate(project, key)
  local store = project.store
  if not project.cfg.translate.provider then
    return notify("set translate.provider to enable machine translation", vim.log.levels.WARN)
  end
  if not store:get(key, store.default_locale) then
    return notify(("'%s' has no %s value to translate from"):format(key, store.default_locale), vim.log.levels.WARN)
  end
  if (project.pending or {})[key] then
    return notify(("'%s' is already being translated"):format(key))
  end
  local targets = {}
  for _, l in ipairs(store.locales) do
    if l ~= store.default_locale then
      table.insert(targets, l)
    end
  end
  if #targets == 0 then
    return notify("there is no other locale to translate into")
  end
  local prompt = ("Re-translate %d locale%s of '%s' from %s? Existing values will be replaced."):format(
    #targets,
    #targets > 1 and "s" or "",
    key,
    store.default_locale
  )
  vim.ui.select({ "Re-translate", "Cancel" }, { prompt = prompt }, function(choice)
    if choice ~= "Re-translate" then
      return
    end
    M.translate_key(project, key, targets, nil, { overwrite = true })
    for buf, s in pairs(sessions) do
      if s.project == project and s.key == key and vim.api.nvim_buf_is_valid(buf) then
        decorate(buf)
        set_title(buf)
      end
    end
  end)
end

--- Saves the float, then re-translates all its locales from the default one.
function M.retranslate_now(buf)
  local s = sessions[buf]
  if not s then
    return
  end
  if vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
  end
  M.retranslate(s.project, s.key)
end

--- Project and key edited in `buf`, when it is an editor float.
function M.session(buf)
  local s = sessions[buf == 0 and vim.api.nvim_get_current_buf() or buf]
  return s and s.project, s and s.key
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
    decorate(buf)
    set_title(buf)
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
  for group, link in pairs({
    I18nTsLocale = "Label",
    I18nTsSource = "Special",
    I18nTsKey = "Special",
    I18nTsModified = "DiagnosticHint",
    I18nTsMissing = "DiagnosticWarn",
    I18nTsPending = "DiagnosticInfo",
    I18nTsDone = "DiagnosticOk",
    I18nTsTitleTag = "Search",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  sessions[buf] = { project = project, key = key, locales = vim.deepcopy(store.locales), help = true }
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  -- Values are free text: completion menus (blink.cmp, nvim-cmp) only get in the way here.
  vim.b[buf].completion = false
  vim.api.nvim_buf_set_name(buf, ("translations://edit/%s/%d"):format(key, buf))
  refill(buf)

  local label, longest = 0, 30
  for _, l in ipairs(store.locales) do
    label = math.max(label, #l)
    longest = math.max(longest, vim.fn.strdisplaywidth(to_line(store:get(key, l))))
  end
  local width = math.min(math.max(label + 6 + longest + 26, legend_width(sessions[buf]), 56), vim.o.columns - 4)
  sessions[buf].width = width
  local height = window_height(sessions[buf])
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })
  sessions[buf].win = win
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  decorate(buf)
  set_title(buf)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      write(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local s = sessions[buf]
      sessions[buf] = nil
      if s and s.project.cfg.translate.auto then
        translate_missing(s.project, s.key, nil, { quiet = true })
      end
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
  -- Configurable actions; `insert`: also mapped in insert mode when the key is a special key like <C-t>.
  local actions = {
    clear = {
      fn = function()
        clear_line(buf)
      end,
    },
    next = {
      insert = true,
      fn = function()
        move(buf, 1)
      end,
    },
    prev = {
      insert = true,
      fn = function()
        move(buf, -1)
      end,
    },
    translate = {
      insert = true,
      fn = function()
        M.translate_now(buf)
      end,
    },
    retranslate = {
      insert = true,
      fn = function()
        M.retranslate_now(buf)
      end,
    },
    help = {
      fn = function()
        toggle_help(buf)
      end,
    },
    close = {
      fn = function()
        M.close(buf)
      end,
    },
    save_close = {
      fn = function()
        vim.cmd("write")
        M.close(buf)
      end,
    },
  }
  for action, spec in pairs(actions) do
    for _, lhs in ipairs(keys_of(project, action)) do
      map(lhs, spec.fn, (spec.insert and lhs:sub(1, 1) == "<") and { "n", "i" } or "n")
    end
  end
  return buf
end

return M
