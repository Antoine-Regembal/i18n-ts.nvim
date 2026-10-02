-- Run with: I18N_TS_PERF_ROOT=/path/to/project I18N_TS_PERF_FILE=src/App.vue nvim --headless -l tests/perf.lua
vim.opt.rtp:prepend(vim.fn.getcwd())

local root = os.getenv("I18N_TS_PERF_ROOT")
local file = os.getenv("I18N_TS_PERF_FILE")
if not root or not file then
  print("set I18N_TS_PERF_ROOT and I18N_TS_PERF_FILE")
  os.exit(1)
end

local function ms(t0)
  return (vim.uv.hrtime() - t0) / 1e6
end

local config = require("i18n-ts.config")
local store_mod = require("i18n-ts.store")
local scanner = require("i18n-ts.scanner")
local display = require("i18n-ts.display")

config.setup({})
local t0 = vim.uv.hrtime()
local cfg = config.for_root(root)
local store = store_mod.new(root, cfg)
print(
  ("detect + resolve: %.1f ms, %d files, sources: %s"):format(ms(t0), #store.files, table.concat(store.sources, ", "))
)

t0 = vim.uv.hrtime()
for _, l in ipairs(store.locales) do
  store:ensure(l)
end
print(("load %d locales: %.1f ms, %d keys in %s"):format(#store.locales, ms(t0), #store:keys(), store.default_locale))

vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. file))
local buf = vim.api.nvim_get_current_buf()
local project = {
  cfg = cfg,
  store = store,
  compiled = scanner.compile(cfg.functions, cfg.patterns),
  locale = store.default_locale,
  enabled = true,
}
t0 = vim.uv.hrtime()
display.render(buf, project)
print(
  ("render visible range: %.2f ms, %d extmarks"):format(
    ms(t0),
    #vim.api.nvim_buf_get_extmarks(buf, display.ns, 0, -1, {})
  )
)
t0 = vim.uv.hrtime()
display.diagnose(buf, project)
print(
  ("diagnose whole buffer (%d lines): %.2f ms, %d diagnostics"):format(
    vim.api.nvim_buf_line_count(buf),
    ms(t0),
    #vim.diagnostic.get(buf, { namespace = display.diag_ns })
  )
)
