local i18n = require("i18n-ts")
local display = require("i18n-ts.display")

local M = {}

local function notify(msg, level)
  vim.notify("i18n-ts: " .. msg, level or vim.log.levels.INFO)
end

function M.jump(pos)
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(pos.path))
  vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.col - 1, 0) })
end

--- Jumps to the key under the cursor in the displayed locale, falling back to the default one.
---@return boolean found
function M.definition()
  local key, project = i18n.key_at_cursor()
  if not key then
    return false
  end
  local store = project.store
  local pos = store:position(key, project.locale) or store:position(key, store.default_locale)
  if not pos then
    notify(("'%s' is missing, :I18n add to create it"):format(key), vim.log.levels.WARN)
    return true
  end
  M.jump(pos)
  return true
end

function M.show()
  local key, project = i18n.key_at_cursor()
  if not key then
    notify("no translation key under the cursor", vim.log.levels.WARN)
    return
  end
  local store = project.store
  local width = 0
  for _, l in ipairs(store.locales) do
    width = math.max(width, #l)
  end
  local lines = { "**" .. key .. "**", "" }
  for _, l in ipairs(store.locales) do
    local value = store:get(key, l)
    table.insert(
      lines,
      ("`%s`  %s"):format(l .. string.rep(" ", width - #l), value and display.format(value, 120) or "_missing_")
    )
  end
  vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded", focus_id = "i18n-ts" })
end

--- Key defined on the cursor line when `buf` is one of the project's translation files.
function M.key_in_json(buf, store)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local path = require("i18n-ts.root").real(vim.api.nvim_buf_get_name(buf))
  local file = store.by_path[path]
  if not file then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local positions = require("i18n-ts.store").index_json(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  for key, pos in pairs(positions) do
    if pos[1] == row then
      return store:key_for(file, key)
    end
  end
end

local function resolve_key(arg)
  if arg and arg ~= "" then
    return arg, i18n.require_project()
  end
  local key, project = i18n.key_at_cursor()
  if key then
    return key, project
  end
  project = i18n.project(0)
  if project then
    return M.key_in_json(0, project.store), project
  end
end

--- Opens the editor float on a key: argument, call under the cursor, or key line in a translation file.
function M.edit(arg)
  local key, project = resolve_key(arg)
  if not project then
    return
  end
  if not key then
    return notify("no translation key under the cursor", vim.log.levels.WARN)
  end
  require("i18n-ts.editor").open(project, key)
end

--- Machine-translates every missing locale of a key from the default locale.
function M.translate(arg)
  local editor = require("i18n-ts.editor")
  local buf = vim.api.nvim_get_current_buf()
  if (not arg or arg == "") and editor.session(buf) then
    return editor.translate_now(buf)
  end
  local key, project = resolve_key(arg)
  if not project then
    return
  end
  if not key then
    return notify("no translation key under the cursor", vim.log.levels.WARN)
  end
  require("i18n-ts.editor").translate_key(project, key)
end

--- Re-translates every locale of a key from the default one, replacing existing values, after confirmation.
function M.retranslate(arg, project)
  local editor = require("i18n-ts.editor")
  local buf = vim.api.nvim_get_current_buf()
  if not project and (not arg or arg == "") and editor.session(buf) then
    return editor.retranslate_now(buf)
  end
  local key = arg
  if not project then
    key, project = resolve_key(arg)
  end
  if not project then
    return
  end
  if not key or key == "" then
    return notify("no translation key under the cursor", vim.log.levels.WARN)
  end
  editor.retranslate(project, key)
end

--- Deletes a key from every locale after confirmation, warning when the code still uses it.
---@param opts? { check_usages?: boolean }
function M.remove(arg, project, opts)
  opts = opts or {}
  local key = arg
  if not project then
    key, project = resolve_key(arg)
  end
  if not project then
    return
  end
  if not key or key == "" then
    return notify("no translation key under the cursor", vim.log.levels.WARN)
  end
  local edit = require("i18n-ts.edit")
  local count = #edit.files_with(project.store, key)
  if count == 0 then
    return notify(("'%s' is not defined in any locale file"):format(key), vim.log.levels.WARN)
  end
  local function confirm(usage_count)
    local prompt = ("Remove '%s' from %d locale file%s?"):format(key, count, count > 1 and "s" or "")
    if usage_count and usage_count > 0 then
      prompt = prompt .. (" It is still used in %d place%s."):format(usage_count, usage_count > 1 and "s" or "")
    end
    vim.ui.select({ "Remove", "Cancel" }, { prompt = prompt }, function(choice)
      if choice ~= "Remove" then
        return
      end
      local removed, errors = edit.remove(project.store, key, { prune = project.cfg.remove.prune_empty })
      i18n.refresh_project(project)
      local msg = ("removed '%s' from %d file(s)"):format(key, #removed)
      for locale, err in pairs(errors) do
        msg = msg .. ("\n%s: %s"):format(locale, err)
      end
      notify(msg, next(errors) and vim.log.levels.WARN or vim.log.levels.INFO)
    end)
  end
  if opts.check_usages == false or vim.fn.executable("rg") ~= 1 then
    return confirm(nil)
  end
  require("i18n-ts.usages").search(project, key, function(err, locations)
    confirm(not err and #locations or nil)
  end)
end

local function prompt_values(store, key, cb)
  local cfg = store.cfg.add
  local values, i = {}, 0
  local locales = store.locales
  local function ask()
    i = i + 1
    local locale = locales[i]
    if not locale then
      return cb(values)
    end
    if store:get(key, locale) then
      return ask()
    end
    local default = values[store.default_locale] or ""
    if cfg.prompt == "default" and locale ~= store.default_locale then
      values[locale] = values[store.default_locale]
      return ask()
    end
    vim.ui.input({ prompt = ("%s [%s]: "):format(key, locale), default = default }, function(input)
      if input == nil then
        return notify("cancelled, nothing written")
      end
      if input ~= "" then
        values[locale] = input
      end
      ask()
    end)
  end
  ask()
end

--- Adds a key (argument, or the missing key under the cursor) to every locale.
function M.add(key)
  local project = i18n.require_project()
  if not project then
    return
  end
  if not key or key == "" then
    key = i18n.key_at_cursor()
  end
  local function run(k)
    if not k or k == "" then
      return
    end
    prompt_values(project.store, k, function(values)
      if vim.tbl_isempty(values) then
        return notify("no value given, nothing written")
      end
      local written, errors = require("i18n-ts.edit").add(project.store, k, values)
      local fmt = project.cfg.add.format_cmd
      if fmt and #written > 0 then
        vim.system(vim.list_extend(vim.deepcopy(fmt), written), { cwd = project.root }):wait()
        for _, path in ipairs(written) do
          project.store:reload_path(path)
        end
      end
      i18n.refresh_project(project)
      local msg = ("added '%s' to %d file(s)"):format(k, #written)
      for locale, err in pairs(errors) do
        msg = msg .. ("\n%s: %s"):format(locale, err)
      end
      notify(msg, next(errors) and vim.log.levels.WARN or vim.log.levels.INFO)
    end)
  end
  if key then
    run(key)
  else
    vim.ui.input({ prompt = "New key: " }, run)
  end
end

return M
