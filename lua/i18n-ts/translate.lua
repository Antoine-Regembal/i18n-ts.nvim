local M = {}

--- Process runner, replaceable in tests.
M.runner = function(cmd, opts, on_exit)
  return vim.system(cmd, opts, on_exit)
end

local SYSTEM_PROMPT = table.concat({
  "You translate user interface strings for a software product.",
  "Translate the source text into every target locale (BCP 47 or ISO 639 codes).",
  "Keep unchanged: {placeholders}, %s and %d tokens, @:linked.keys, the | plural separators, HTML tags,",
  "leading and trailing whitespace. Keep a length close to the source and the same tone.",
  "The key is context only: never translate it.",
}, " ")

local function curl_config(headers)
  local lines = {}
  for _, h in ipairs(headers) do
    table.insert(lines, ('header = "%s"'):format(h:gsub("\\", "\\\\"):gsub('"', '\\"')))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- POSTs `body` with secret headers passed on stdin, so they never show in the process list.
local function post(url, headers, body, cb)
  local tmp = vim.fn.tempname()
  local fd = assert(io.open(tmp, "w"))
  fd:write(vim.json.encode(body))
  fd:close()
  local cmd = {
    "curl",
    "-sS",
    "-X",
    "POST",
    url,
    "-K",
    "-",
    "--data-binary",
    "@" .. tmp,
    "-w",
    "\n%{http_code} %header{retry-after}",
  }
  M.runner(cmd, { stdin = curl_config(headers), text = true }, function(res)
    os.remove(tmp)
    if res.code ~= 0 then
      return cb("curl failed: " .. vim.trim(res.stderr or ""))
    end
    local out = res.stdout or ""
    local payload, status, retry = out:match("^(.*)\n(%d+) ?(%S*)%s*$")
    if not status then
      return cb("unexpected response")
    end
    local ok, decoded = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
    cb(nil, tonumber(status), ok and decoded or nil, tonumber(retry))
  end)
end

local function with_retry(cfg, attempt_fn, cb)
  attempt_fn(function(err, status, body, retry_after)
    local retryable = status and (status == 429 or status >= 500)
    if not err and retryable then
      local delay = retry_after and math.min(retry_after, 10) * 1000 or cfg.retry_delay_ms
      vim.defer_fn(function()
        attempt_fn(cb)
      end, math.max(delay, cfg.retry_delay_ms))
      return
    end
    cb(err, status, body)
  end)
end

local function api_error(body, status)
  local msg = type(body) == "table" and type(body.error) == "table" and body.error.message
  return ("HTTP %d%s"):format(status, msg and (": " .. msg) or "")
end

local function only_targets(result, targets)
  local out = {}
  for _, l in ipairs(targets) do
    if type(result[l]) == "string" and result[l] ~= "" then
      out[l] = result[l]
    end
  end
  return out
end

local function target_schema(targets, optional)
  local properties = {}
  for _, l in ipairs(targets) do
    properties[l] = { type = "string" }
  end
  local schema = { type = "object", properties = properties, additionalProperties = false }
  if not optional then
    schema.required = targets
  end
  return schema
end

function M.anthropic_body(acfg, req, context)
  return {
    model = acfg.model,
    max_tokens = acfg.max_tokens,
    system = SYSTEM_PROMPT .. (context and (" Context: " .. context) or ""),
    messages = {
      {
        role = "user",
        content = vim.json.encode({
          key = req.key,
          source_locale = req.source_locale,
          source = req.source,
          targets = req.targets,
        }),
      },
    },
    output_config = { format = { type = "json_schema", schema = target_schema(req.targets) } },
  }
end

local providers = {}

function providers.anthropic(cfg, req, cb)
  local acfg = cfg.anthropic
  local key = vim.env[acfg.api_key_env]
  if not key or key == "" then
    return cb(acfg.api_key_env .. " is not set")
  end
  local headers = { "x-api-key: " .. key, "anthropic-version: 2023-06-01", "content-type: application/json" }
  local body = M.anthropic_body(acfg, req, cfg.context)
  with_retry(cfg, function(done)
    post(acfg.base_url .. "/v1/messages", headers, body, done)
  end, function(err, status, res)
    if err then
      return cb(err)
    end
    if status == 401 or status == 403 then
      return cb(("invalid API key (%s): %s"):format(acfg.api_key_env, api_error(res, status)))
    end
    if status ~= 200 or type(res) ~= "table" then
      return cb(api_error(res, status))
    end
    if res.stop_reason == "refusal" then
      return cb("the model refused to translate this text")
    end
    if res.stop_reason == "max_tokens" then
      return cb("answer cut at max_tokens, raise translate.anthropic.max_tokens")
    end
    for _, block in ipairs(res.content or {}) do
      if block.type == "text" then
        local ok, decoded = pcall(vim.json.decode, block.text)
        if ok and type(decoded) == "table" then
          return cb(nil, only_targets(decoded, req.targets))
        end
      end
    end
    cb("no translation in the answer")
  end)
end

--- Name of the Claude Code executable, for messages.
function M.claude_name(ccfg)
  return type(ccfg.cmd) == "table" and tostring(ccfg.cmd[1]) or tostring(ccfg.cmd)
end

--- `claude -p` argv shared by one-shot calls and sessions; `ccfg.cmd` may be a string or a list.
function M.claude_argv(cfg, schema, system_suffix, extra)
  local ccfg = cfg.claude_code
  local cmd = type(ccfg.cmd) == "table" and vim.deepcopy(ccfg.cmd) or { ccfg.cmd }
  vim.list_extend(cmd, {
    "-p",
    "--model",
    ccfg.model,
    "--json-schema",
    vim.json.encode(schema),
    "--system-prompt",
    SYSTEM_PROMPT .. (system_suffix or "") .. (cfg.context and (" Context: " .. cfg.context) or ""),
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
  })
  if ccfg.max_budget_usd then
    vim.list_extend(cmd, { "--max-budget-usd", tostring(ccfg.max_budget_usd) })
  end
  vim.list_extend(cmd, ccfg.extra_args or {})
  return vim.list_extend(cmd, extra or {})
end

function M.claude_message(req)
  return vim.json.encode({
    key = req.key,
    source_locale = req.source_locale,
    source = req.source,
    targets = req.targets,
  })
end

--- Translations from a Claude Code `result` object (one-shot output or session event).
function M.parse_claude_result(out, req, name)
  if out.is_error then
    return ("%s: %s"):format(name, tostring(out.result or out.subtype or "error"))
  end
  local result = out.structured_output
  if type(result) ~= "table" and type(out.result) == "string" then
    local parsed_ok, parsed = pcall(vim.json.decode, out.result)
    result = parsed_ok and parsed or nil
  end
  if type(result) ~= "table" then
    return "no translation in the Claude Code answer"
  end
  return nil, only_targets(result, req.targets)
end

--- One `claude -p` per request: no state, ~5 s per call (CLI start-up included).
local function claude_oneshot(cfg, req, cb)
  local name = M.claude_name(cfg.claude_code)
  local cmd = M.claude_argv(cfg, target_schema(req.targets), nil, { "--output-format", "json" })
  -- A neutral cwd keeps the project's CLAUDE.md out of the prompt.
  local opts = { stdin = M.claude_message(req), text = true, cwd = vim.fn.stdpath("cache") }
  local ok, err = pcall(M.runner, cmd, opts, function(res)
    local decoded_ok, out = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
    if not decoded_ok or type(out) ~= "table" then
      local detail = vim.trim(res.stderr or "")
      return cb(
        ("unexpected output from %s (exit %d)%s"):format(name, res.code, detail ~= "" and (": " .. detail) or "")
      )
    end
    cb(M.parse_claude_result(out, req, name))
  end)
  if not ok then
    cb(("cannot run %s: %s"):format(name, tostring(err)))
  end
end

--- Runs the Claude Code CLI headless, so it uses its own login (subscription or API key) instead of a key here.
--- By default through a warm session (`claude_session.lua`), falling back to one-shot calls when it fails.
function providers.claude_code(cfg, req, cb)
  if cfg.claude_code.session == false then
    return claude_oneshot(cfg, req, cb)
  end
  require("i18n-ts.claude_session").request(cfg, req, function(err, event, fallback)
    if fallback then
      return claude_oneshot(cfg, req, cb)
    end
    if err then
      return cb(err)
    end
    cb(M.parse_claude_result(event, req, M.claude_name(cfg.claude_code)))
  end)
end

--- Starts the warm Claude Code session of a project ahead of the first translation.
function M.prewarm(cfg, locales)
  local ccfg = cfg.claude_code
  if cfg.provider ~= "claude_code" or ccfg.session == false or ccfg.prewarm == false or #locales == 0 then
    return
  end
  require("i18n-ts.claude_session").prewarm(cfg, locales, { warmup = ccfg.prewarm ~= "process" })
end

M.target_schema = target_schema

local deepl_targets = { en = "EN-US", pt = "PT-PT", cmn = "ZH-HANS", zh = "ZH-HANS" }

local function deepl_code(locale, as_target)
  local n = locale:lower():gsub("_", "-")
  local base = n:match("^([^-]+)")
  if not as_target then
    return (base == "cmn" and "ZH" or base):upper()
  end
  return deepl_targets[n] or n:upper()
end

function providers.deepl(cfg, req, cb)
  local key = vim.env[cfg.deepl.api_key_env]
  if not key or key == "" then
    return cb(cfg.deepl.api_key_env .. " is not set")
  end
  local host = key:match(":fx$") and "https://api-free.deepl.com" or "https://api.deepl.com"
  local headers = { "Authorization: DeepL-Auth-Key " .. key, "content-type: application/json" }
  local result, errors, pending = {}, {}, #req.targets
  for _, locale in ipairs(req.targets) do
    local body = {
      text = { req.source },
      source_lang = deepl_code(req.source_locale, false),
      target_lang = deepl_code(locale, true),
    }
    with_retry(cfg, function(done)
      post(host .. "/v2/translate", headers, body, done)
    end, function(err, status, res)
      if err or status ~= 200 then
        errors[locale] = err or api_error(res, status)
      elseif res and res.translations and res.translations[1] then
        result[locale] = res.translations[1].text
      end
      pending = pending - 1
      if pending == 0 then
        cb(next(result) == nil and next(errors) and "DeepL failed for every locale" or nil, result, errors)
      end
    end)
  end
end

function providers.command(cfg, req, cb)
  if type(cfg.command) ~= "table" or #cfg.command == 0 then
    return cb("translate.command is not set")
  end
  M.runner(cfg.command, { stdin = vim.json.encode(req), text = true }, function(res)
    if res.code ~= 0 then
      return cb(("command exited with %d: %s"):format(res.code, vim.trim(res.stderr or "")))
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout or "")
    if not ok or type(decoded) ~= "table" then
      return cb("command did not print a JSON object")
    end
    cb(nil, only_targets(decoded, req.targets))
  end)
end

--- Translates `req.source` into `req.targets`; `cb(err, { [locale] = text }, per_locale_errors)` runs on the main loop.
function M.run(cfg, req, cb)
  local done = vim.schedule_wrap(function(err, result, errors)
    cb(err, result or {}, errors or {})
  end)
  local provider = cfg.provider
  if type(provider) == "function" then
    local ok, err = pcall(provider, req, function(e, r)
      done(e, r and only_targets(r, req.targets))
    end)
    if not ok then
      done(tostring(err))
    end
    return
  end
  local fn = providers[provider]
  if not fn then
    return done(("unknown translate.provider '%s'"):format(tostring(provider)))
  end
  fn(cfg, req, done)
end

function M.label(cfg)
  if cfg.provider == "anthropic" then
    return cfg.anthropic.model
  elseif cfg.provider == "claude_code" then
    return "Claude Code, " .. cfg.claude_code.model
  end
  return type(cfg.provider) == "function" and "custom provider" or tostring(cfg.provider)
end

return M
