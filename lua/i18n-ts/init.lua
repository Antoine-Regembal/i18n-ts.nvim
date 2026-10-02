local config = require("i18n-ts.config")
local root_mod = require("i18n-ts.root")
local store_mod = require("i18n-ts.store")
local scanner = require("i18n-ts.scanner")
local display = require("i18n-ts.display")

local M = {}

---@type table<string, table> project per root
M.projects = {}
local attached = {}
local timers = {}
local group = vim.api.nvim_create_augroup("i18n-ts", { clear = true })

M.register_parser = store_mod.register_parser

local function notify(msg, level)
  vim.notify("i18n-ts: " .. msg, level or vim.log.levels.INFO)
end

local function buf_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
end

--- Project for a buffer (or the cwd), created on first use; nil when the root has no translation files.
function M.project(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local root = root_mod.find(buf_dir(buf), config.options.root_markers)
  if not root then
    return nil
  end
  local project = M.projects[root]
  if project == nil then
    local cfg, err = config.for_root(root)
    local store = store_mod.new(root, cfg)
    if err then
      notify(err, vim.log.levels.WARN)
    end
    project = store:has_files()
        and {
          root = root,
          cfg = cfg,
          store = store,
          compiled = scanner.compile(cfg.functions, cfg.patterns),
          locale = store.default_locale,
          enabled = true,
          pending = {},
        }
      or false
    M.projects[root] = project
    if project then
      store:load_async(function()
        M.refresh_project(project)
      end)
      require("i18n-ts.translate").prewarm(cfg.translate, require("i18n-ts.editor").other_locales(store))
    end
  end
  return project or nil
end

local function each_attached(project, fn)
  for buf, p in pairs(attached) do
    if p == project and vim.api.nvim_buf_is_valid(buf) then
      fn(buf)
    end
  end
end

local function update(buf, with_diagnostics)
  local project = attached[buf]
  if not project or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  display.render(buf, project)
  if with_diagnostics then
    display.diagnose(buf, project)
  end
end

local function schedule(buf, with_diagnostics)
  local project = attached[buf]
  if not project then
    return
  end
  local timer = timers[buf]
  if not timer then
    timer = vim.uv.new_timer()
    timers[buf] = timer
  end
  timer:stop()
  timer:start(
    project.cfg.debounce_ms,
    0,
    vim.schedule_wrap(function()
      update(buf, with_diagnostics)
    end)
  )
end

local spinner

--- Animates the "translating…" indicator of every attached buffer while a project has pending translations.
function M.track_pending(project)
  if M.projects[project.root] == nil then
    M.projects[project.root] = project
  end
  M.refresh_project(project)
  if spinner then
    return
  end
  spinner = vim.uv.new_timer()
  spinner:start(
    120,
    120,
    vim.schedule_wrap(function()
      display.frame = display.frame % #display.spinner + 1
      require("i18n-ts.editor").tick()
      local busy = false
      for _, p in pairs(M.projects) do
        if p and p.pending and next(p.pending) then
          busy = true
          each_attached(p, function(buf)
            display.render(buf, p)
          end)
        end
      end
      if not busy and spinner then
        spinner:stop()
        spinner:close()
        spinner = nil
      end
    end)
  )
end

function M.refresh_project(project)
  each_attached(project, function(buf)
    update(buf, true)
  end)
end

function M.attach(buf)
  if attached[buf] ~= nil or vim.bo[buf].buftype ~= "" then
    return
  end
  local project = M.project(buf)
  if not project or not vim.tbl_contains(project.cfg.filetypes, vim.bo[buf].filetype) then
    return
  end
  attached[buf] = project
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinScrolled", "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      schedule(buf, ev.event ~= "WinScrolled" and ev.event ~= "TextChangedI")
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      attached[buf] = nil
      if timers[buf] then
        timers[buf]:close()
        timers[buf] = nil
      end
    end,
  })
  update(buf, true)
end

function M.setup(opts)
  config.setup(opts)
  M.projects = {}
  vim.api.nvim_set_hl(0, "I18nTsTranslation", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "I18nTsMissing", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "I18nTsLocale", { link = "Label", default = true })
  vim.api.nvim_set_hl(0, "I18nTsPending", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.options.filetypes,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = group,
    pattern = "*.json",
    callback = function(ev)
      local path = root_mod.real(vim.api.nvim_buf_get_name(ev.buf))
      for _, project in pairs(M.projects) do
        if project and project.store:owns(path) then
          project.store:reload_path(path)
          M.refresh_project(project)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    callback = function()
      for _, project in pairs(M.projects) do
        if project and project.store:refresh() then
          M.refresh_project(project)
        end
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(config.options.filetypes, vim.bo[buf].filetype) then
      M.attach(buf)
    end
  end
end

--- Translation call under the cursor (or the first one on the line).
function M.key_at_cursor()
  local project = attached[vim.api.nvim_get_current_buf()]
  if not project then
    return nil
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local hits = scanner.scan({ line }, project.compiled, row - 1)
  for _, hit in ipairs(hits) do
    if col >= hit.col - 1 and col <= hit.call_end then
      return hit.key, project
    end
  end
  return hits[1] and hits[1].key, project
end

function M.require_project()
  local project = attached[vim.api.nvim_get_current_buf()] or M.project(0)
  if not project then
    notify("no translation files found for this buffer (see :checkhealth i18n-ts)", vim.log.levels.WARN)
  end
  return project
end

function M.definition()
  return require("i18n-ts.navigation").definition()
end

function M.next_locale()
  local project = M.require_project()
  if not project then
    return
  end
  local locales = project.store.locales
  local idx = 1
  for i, l in ipairs(locales) do
    if l == project.locale then
      idx = i
    end
  end
  project.locale = locales[idx % #locales + 1]
  M.refresh_project(project)
  notify("showing " .. project.locale)
end

function M.toggle()
  local project = M.require_project()
  if not project then
    return
  end
  project.enabled = not project.enabled
  each_attached(project, function(buf)
    if project.enabled then
      update(buf, true)
    else
      display.clear(buf)
    end
  end)
end

function M.reload()
  for _, project in pairs(M.projects) do
    if project then
      each_attached(project, display.clear)
    end
  end
  for buf in pairs(attached) do
    attached[buf] = nil
  end
  M.projects = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.attach(buf)
    end
  end
end

function M.is_attached(buf)
  return attached[buf == 0 and vim.api.nvim_get_current_buf() or buf] ~= nil
end

function M.info()
  local project = M.project(0)
  if not project then
    notify("no translation files found for this buffer", vim.log.levels.WARN)
    return
  end
  local s = project.store
  local lines = {
    "root:     " .. project.root,
    "sources:  " .. table.concat(s.sources, ", ") .. (s.detected and "  (auto-detected)" or ""),
    "locales:  " .. table.concat(s.locales, ", "),
    "showing:  " .. project.locale,
    ("keys:     %d in %s"):format(#s:keys(s.default_locale), s.default_locale),
  }
  if project.cfg.translate.provider == "claude_code" then
    for _, w in ipairs(require("i18n-ts.claude_session").status(project.cfg.translate)) do
      table.insert(
        lines,
        ("claude:   %s, %d turn(s), %d start(s), up %ds"):format(w.state, w.turns, w.spawns, w.uptime_ms / 1000)
      )
    end
  end
  for path, err in pairs(s.errors) do
    table.insert(lines, "error:    " .. vim.fn.fnamemodify(path, ":~:.") .. ": " .. err)
  end
  notify(table.concat(lines, "\n"))
end

M.subcommands = {
  def = function()
    require("i18n-ts.navigation").definition()
  end,
  show = function()
    require("i18n-ts.navigation").show()
  end,
  next = M.next_locale,
  keys = function()
    require("i18n-ts.picker").keys()
  end,
  add = function(arg)
    require("i18n-ts.navigation").add(arg)
  end,
  edit = function(arg)
    require("i18n-ts.navigation").edit(arg)
  end,
  translate = function(arg)
    require("i18n-ts.navigation").translate(arg)
  end,
  retranslate = function(arg)
    require("i18n-ts.navigation").retranslate(arg)
  end,
  remove = function(arg)
    require("i18n-ts.navigation").remove(arg)
  end,
  usages = function(arg)
    require("i18n-ts.usages").find(arg)
  end,
  toggle = M.toggle,
  reload = M.reload,
  info = M.info,
}

return M
