--- Warm Claude Code sessions: one long-lived `claude -p --input-format stream-json` process per locale set,
--- receiving each translation as a new message instead of starting the CLI for every key.
local translate = require("i18n-ts.translate")

local M = {}

local SESSION_SUFFIX = " Each user message is an independent request: ignore the earlier ones."
local WARMUP = vim.json.encode({ warmup = true, targets = {} })

---@type table<string, table>
local workers = {}

local function now()
  return vim.uv.now()
end

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function worker_key(cfg, locales)
  local sorted = vim.deepcopy(locales)
  table.sort(sorted)
  local ccfg = cfg.claude_code
  return table.concat({ vim.inspect(ccfg.cmd), ccfg.model, cfg.context or "", table.concat(sorted, ",") }, "|")
end

local function kill(w)
  stop_timer(w.idle_timer)
  stop_timer(w.request_timer)
  w.idle_timer, w.request_timer = nil, nil
  if w.proc then
    w.expected[w.proc] = true
    pcall(w.proc.kill, w.proc, 15)
  end
  w.proc, w.state = nil, "stopped"
end

local pump

local function finish_current(w, err, event, fallback)
  local job = w.current
  w.current = nil
  w.state = w.proc and "ready" or "stopped"
  stop_timer(w.request_timer)
  w.request_timer = nil
  if job then
    job.cb(err, event, fallback)
  end
  pump(w)
end

local function on_line(w, proc, line)
  if w.proc ~= proc or line == "" then
    return
  end
  local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(event) ~= "table" then
    return
  end
  if event.type ~= "result" or not w.current then
    return
  end
  w.turns = w.turns + 1
  w.last_used = now()
  if w.turns >= w.cfg.claude_code.max_turns then
    kill(w)
  end
  finish_current(w, nil, event, false)
end

local function on_exit(w, proc, code)
  if w.expected[proc] then
    w.expected[proc] = nil
    return
  end
  if w.proc ~= proc then
    return
  end
  w.proc, w.state = nil, "stopped"
  stop_timer(w.idle_timer)
  w.idle_timer = nil
  -- The current request is retried once through a one-shot call; the next request restarts the session.
  if w.current then
    finish_current(w, ("Claude Code session exited (%d)"):format(code), nil, true)
  end
end

local function spawn(w)
  local cmd = translate.claude_argv(
    w.cfg,
    translate.target_schema(w.locales, true),
    SESSION_SUFFIX,
    { "--input-format", "stream-json", "--output-format", "stream-json", "--verbose" }
  )
  local buffer = ""
  local proc
  local ok, err = pcall(function()
    proc = translate.runner(cmd, {
      stdin = true,
      text = true,
      cwd = vim.fn.stdpath("cache"),
      stdout = function(_, data)
        if not data then
          return
        end
        buffer = buffer .. data
        local lines = {}
        while true do
          local nl = buffer:find("\n", 1, true)
          if not nl then
            break
          end
          table.insert(lines, buffer:sub(1, nl - 1))
          buffer = buffer:sub(nl + 1)
        end
        if #lines > 0 then
          vim.schedule(function()
            for _, line in ipairs(lines) do
              on_line(w, proc, line)
            end
          end)
        end
      end,
    }, function(res)
      vim.schedule(function()
        on_exit(w, proc, res.code)
      end)
    end)
  end)
  if not ok or not proc then
    w.state = "stopped"
    return false, tostring(err)
  end
  w.proc, w.state, w.turns, w.started = proc, "ready", 0, now()
  w.spawns = w.spawns + 1
  return true
end

local function arm_idle(w)
  stop_timer(w.idle_timer)
  local timeout = w.cfg.claude_code.idle_timeout_ms
  if not timeout or timeout <= 0 or not w.proc then
    return
  end
  w.idle_timer = vim.uv.new_timer()
  w.idle_timer:start(
    timeout,
    0,
    vim.schedule_wrap(function()
      if not w.current and #w.queue == 0 then
        kill(w)
      end
    end)
  )
end

function pump(w)
  if w.current then
    return
  end
  local job = table.remove(w.queue, 1)
  if not job then
    arm_idle(w)
    return
  end
  stop_timer(w.idle_timer)
  w.idle_timer = nil
  if not w.proc then
    local ok, err = spawn(w)
    if not ok then
      job.cb("cannot start Claude Code: " .. err, nil, true)
      return pump(w)
    end
  end
  w.current = job
  w.state = "busy"
  local line = vim.json.encode({ type = "user", message = { role = "user", content = job.message } }) .. "\n"
  local wrote = pcall(w.proc.write, w.proc, line)
  if not wrote then
    kill(w)
    return finish_current(w, "Claude Code session is gone", nil, true)
  end
  local timeout = w.cfg.claude_code.request_timeout_ms
  if timeout and timeout > 0 then
    w.request_timer = vim.uv.new_timer()
    w.request_timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        if w.current == job then
          kill(w)
          finish_current(w, ("translation timed out after %d ms"):format(timeout), nil, false)
        end
      end)
    )
  end
end

local function get(cfg, locales)
  local key = worker_key(cfg, locales)
  local w = workers[key]
  if not w then
    w = {
      key = key,
      cfg = cfg,
      locales = vim.deepcopy(locales),
      queue = {},
      expected = {},
      turns = 0,
      spawns = 0,
      state = "stopped",
    }
    workers[key] = w
  end
  return w
end

local function enqueue(w, message, cb)
  table.insert(w.queue, { message = message, cb = cb })
  pump(w)
end

--- Sends `req` to the session for its locale set; `cb(err, result_event, fallback)` runs on the main loop.
--- `fallback` is true when the session failed and the caller should retry without it.
function M.request(cfg, req, cb)
  local w = get(cfg, req.schema_locales or req.targets)
  enqueue(w, translate.claude_message(req), cb)
end

--- Starts the session now; with `opts.warmup`, also sends a tiny message so the CLI finishes initialising.
function M.prewarm(cfg, locales, opts)
  local w = get(cfg, locales)
  if w.proc or w.current or #w.queue > 0 then
    return
  end
  if opts and opts.warmup then
    enqueue(w, WARMUP, function() end)
  else
    spawn(w)
    arm_idle(w)
  end
end

--- Worker states for health and `:I18n info`, optionally limited to the ones `cfg` would use.
function M.status(cfg)
  local list = {}
  for _, w in pairs(workers) do
    if not cfg or vim.deep_equal(w.cfg.claude_code.cmd, cfg.claude_code.cmd) then
      table.insert(list, {
        state = w.proc and w.state or "stopped",
        turns = w.turns,
        spawns = w.spawns,
        queued = #w.queue,
        uptime_ms = w.proc and (now() - w.started) or 0,
        locales = w.locales,
      })
    end
  end
  return list
end

function M.stop_all()
  for key, w in pairs(workers) do
    kill(w)
    workers[key] = nil
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("i18n-ts.claude_session", { clear = true }),
  callback = M.stop_all,
})

return M
