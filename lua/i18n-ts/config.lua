local M = {}

M.defaults = {
  -- Markers tried in order; the first one found upwards from the buffer is the project root.
  root_markers = { ".i18n-ts.json", ".git", "package.json" },
  -- Translation files relative to the root. `{locale}` is required, `{namespace}` optional.
  -- Empty: auto-detected from the usual layouts.
  sources = {},
  -- Empty: every locale found in the sources, sorted, `default_locale` first.
  locales = {},
  -- Always listed first, and the source of machine translations. Matched leniently: `en_us`, then `en`, then `en-*`.
  default_locale = "en-US",
  -- Prefix keys from `{namespace}` files with `<namespace><separator>`.
  namespace_separator = ".",
  -- Namespace tried when a key has none (i18next `defaultNS`).
  default_namespace = nil,
  -- Translation call names; matched after any non-identifier char, so `i18n.global.t(` and `this.$t(` work.
  functions = { "t", "$t", "tc", "te", "tm" },
  -- Extra Lua patterns with one capture for the key, e.g. `i18nKey="([^"]+)"`.
  patterns = {},
  filetypes = { "vue", "typescript", "javascript", "typescriptreact", "javascriptreact", "svelte" },
  display = {
    -- "eol", "inline" or "off"
    mode = "eol",
    max_len = 60,
    prefix = " ",
  },
  diagnostics = {
    enabled = true,
    severity = vim.diagnostic.severity.WARN,
    -- Also report keys missing in the other locales, as hints.
    all_locales = false,
  },
  auto_detect = {
    depth = 4,
    dir_names = { "locales", "locale", "i18n", "lang", "langs", "messages", "translations" },
    skip = { "node_modules", "dist", "build", "coverage", "vendor" },
  },
  add = {
    -- "all": prompt a value for every locale; "default": reuse the default locale's value everywhere.
    prompt = "all",
    -- Formatter run on the written files, e.g. { "npx", "prettier", "--write" }. Never read from project files.
    format_cmd = nil,
  },
  remove = {
    -- Also delete parent objects left empty by `:I18n remove`.
    prune_empty = true,
  },
  -- Fills empty locales from the default one. Sends the source text to the provider; never read from project files.
  translate = {
    -- nil (off), "claude_code", "anthropic", "deepl", "command", or fun(request, callback)
    provider = nil,
    -- Translate the empty locales when the editor is written.
    auto = true,
    -- Extra instruction for the model, e.g. "Medical software used by doctors."
    context = nil,
    -- Uses the Claude Code CLI login: no API key needed.
    claude_code = {
      cmd = "claude",
      model = "claude-haiku-4-5",
      -- Hard cap per call, in USD (`--max-budget-usd`); nil to disable.
      max_budget_usd = 0.05,
      extra_args = {},
    },
    anthropic = {
      model = "claude-haiku-4-5",
      api_key_env = "ANTHROPIC_API_KEY",
      base_url = "https://api.anthropic.com",
      max_tokens = 2048,
    },
    deepl = { api_key_env = "DEEPL_API_KEY" },
    -- argv; gets {key, source_locale, source, targets} as JSON on stdin, prints {locale = text}.
    command = nil,
    retry_delay_ms = 2000,
  },
  -- Per-root overrides from your own config, keyed by path: { ["~/Code/app"] = { sources = { ... } } }.
  projects = {},
  debounce_ms = 80,
}

-- Keys a committed `.i18n-ts.json` may set. Anything that runs a command stays out.
local project_file_keys = {
  sources = "table",
  locales = "table",
  default_locale = "string",
  namespace_separator = "string",
  default_namespace = "string",
  functions = "table",
  patterns = "table",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local projects = {}
  for path, override in pairs(M.options.projects or {}) do
    projects[require("i18n-ts.root").real(vim.fn.expand(path))] = override
  end
  M.options.projects = projects
  return M.options
end

local function replace_lists(target, source)
  for k, v in pairs(source) do
    if type(v) == "table" and vim.islist(v) then
      target[k] = vim.deepcopy(v)
    elseif type(v) == "table" and type(target[k]) == "table" then
      replace_lists(target[k], v)
    else
      target[k] = v
    end
  end
  return target
end

---@return table|nil config, string|nil err
function M.read_project_file(root)
  local path = root .. "/.i18n-ts.json"
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return nil, path .. ": invalid JSON"
  end
  local clean = {}
  for k, v in pairs(decoded) do
    local expected = project_file_keys[k]
    if expected and type(v) == expected then
      clean[k] = v
    end
  end
  return clean
end

--- Effective options for a root: defaults < setup() < .i18n-ts.json < setup().projects[root].
function M.for_root(root)
  local resolved = vim.deepcopy(M.options)
  resolved.projects = nil
  local file_cfg, err = M.read_project_file(root)
  if file_cfg then
    replace_lists(resolved, file_cfg)
  end
  local override = M.options.projects[root]
  if override then
    replace_lists(resolved, override)
  end
  return resolved, err
end

return M
