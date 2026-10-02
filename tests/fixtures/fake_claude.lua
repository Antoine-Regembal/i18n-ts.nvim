-- Fake Claude Code CLI for tests: `nvim -l tests/fixtures/fake_claude.lua <claude args>`.
-- With --input-format stream-json it answers each stdin line like a session, otherwise once like `claude -p`.
-- Each answer translates `source` into "<locale>:<source>". Env: FAKE_CLAUDE_SPAWNS (file, one line per start),
-- FAKE_CLAUDE_CRASH_ON (exit on that message), FAKE_CLAUDE_DELAY_MS (delay per answer).
local spawns = os.getenv("FAKE_CLAUDE_SPAWNS")
if spawns then
  local fd = assert(io.open(spawns, "a"))
  fd:write("spawn\n")
  fd:close()
end
local crash_on = tonumber(os.getenv("FAKE_CLAUDE_CRASH_ON") or "")
local delay = tonumber(os.getenv("FAKE_CLAUDE_DELAY_MS") or "0") or 0

local function answer(content, n)
  local ok, req = pcall(vim.json.decode, content)
  local out = {}
  if ok and type(req) == "table" then
    for _, l in ipairs(req.targets or {}) do
      out[l] = l .. ":" .. req.source
    end
  end
  return {
    type = "result",
    subtype = "success",
    is_error = false,
    structured_output = out,
    usage = { input_tokens = 100 * n },
  }
end

if not vim.tbl_contains(_G.arg, "stream-json") then
  io.write(vim.json.encode(answer(io.read("*a"), 1)))
  return
end

local n = 0
for line in io.lines() do
  n = n + 1
  if crash_on and n == crash_on then
    os.exit(3)
  end
  local msg = vim.json.decode(line)
  if n == 1 then
    io.write(vim.json.encode({ type = "system", subtype = "init" }) .. "\n")
  end
  if delay > 0 then
    vim.uv.sleep(delay)
  end
  io.write(vim.json.encode(answer(msg.message.content, n)) .. "\n")
  io.flush()
end
