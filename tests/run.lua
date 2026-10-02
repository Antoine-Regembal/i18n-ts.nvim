-- Run with: nvim --headless -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.getcwd())

local config = require("i18n-ts.config")
local store_mod = require("i18n-ts.store")
local scanner = require("i18n-ts.scanner")
local edit = require("i18n-ts.edit")
local usages = require("i18n-ts.usages")

local fixtures = vim.fs.normalize(vim.fn.getcwd() .. "/tests/fixtures")
local failures, count = 0, 0

local function test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(a, b)
  assert(vim.deep_equal(a, b), ("expected %s, got %s"):format(vim.inspect(b), vim.inspect(a)))
end

local function store_for(name, opts)
  config.setup(vim.tbl_extend("force", { root_markers = { ".i18n-ts.json", "package.json" } }, opts or {}))
  local root = fixtures .. "/" .. name
  return store_mod.new(root, (config.for_root(root)))
end

local function read(path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  return vim.split(content, "\n", { plain = true })
end

-- store

test("auto-detects src/locales/{locale}.json and orders the default locale first", function()
  local store = store_for("vue")
  eq(store.sources, { "src/locales/{locale}.json" })
  eq(store.locales, { "en", "fr" })
  eq(store.default_locale, "en")
end)

test("flattens nested keys and keeps multiline values", function()
  local store = store_for("vue")
  eq(store:get("common.actions.save"), "Save")
  eq(store:get("common.actions.save", "fr"), "Enregistrer")
  eq(store:get("multiline"), "Line one\nLine two")
  eq(store:get("list.2"), "second")
  eq(store:get("common.actions.cancel", "fr"), nil)
end)

test("positions are exact for duplicate leaf names", function()
  local store = store_for("vue")
  eq(store:position("common.title").line, 3)
  eq(store:position("home.title").line, 10)
  eq(store:position("common.actions.cancel").line, 6)
  eq(store:position("common.title").col, 5)
end)

test("array items fall back to the array's line", function()
  local store = store_for("vue")
  eq(store:position("list.1").line, 14)
end)

test("i18next layout: {locale}/{namespace}.json prefixes keys with the namespace", function()
  local store = store_for("i18next", { namespace_separator = ":" })
  eq(store.sources, { "public/locales/{locale}/{namespace}.json" })
  eq(store:get("common:hello", "fr"), "Bonjour")
  eq(store:get("common:nested.deep"), "Deep")
  eq(store:position("common:nested.deep").line, 4)
end)

test("default_namespace resolves keys written without a namespace", function()
  local store = store_for("i18next", { namespace_separator = ":", default_namespace = "common" })
  eq(store:get("hello"), "Hello")
end)

test("flat JSON keys are indexed as-is", function()
  local store = store_for("flat")
  eq(store:get("a.b"), "Flat AB")
  eq(store:position("a.b").line, 2)
end)

test(".i18n-ts.json sets sources and functions, but never format_cmd", function()
  local store = store_for("custom")
  eq(store.sources, { "i18n/messages/{locale}.json" })
  eq(store.cfg.functions, { "translate" })
  eq(store.cfg.add.format_cmd, nil)
  eq(store.locales, { "en", "de" })
end)

test("setup().projects overrides the project file", function()
  local root = fixtures .. "/custom"
  local store = store_for("custom", { projects = { [root] = { locales = { "de" } } } })
  eq(store.locales, { "de" })
  eq(store.default_locale, "de")
end)

test("auto-detect never enters node_modules", function()
  local root = fixtures .. "/custom"
  local sources = store_mod.detect_sources(root, config.defaults.auto_detect)
  eq(sources, { "i18n/messages/{locale}.json" })
end)

test("refresh reloads a locale whose file changed on disk", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/locales", "p")
  vim.fn.writefile({ "{}" }, tmp .. "/package.json")
  vim.fn.writefile({ "{", '  "k": "v1"', "}" }, tmp .. "/locales/en.json")
  config.setup({ root_markers = { "package.json" } })
  local store = store_mod.new(tmp, (config.for_root(tmp)))
  eq(store:get("k"), "v1")
  vim.uv.sleep(20)
  vim.fn.writefile({ "{", '  "k": "v2"', "}" }, tmp .. "/locales/en.json")
  eq(store:refresh(), true)
  eq(store:get("k"), "v2")
  vim.fn.delete(tmp, "rf")
end)

-- scanner

test("scanner finds t, $t, te and member calls, skips template literals and other identifiers", function()
  local compiled = scanner.compile(config.defaults.functions)
  local hits = scanner.scan(read(fixtures .. "/vue/src/App.vue"), compiled, 0)
  local keys = vim.tbl_map(function(h)
    return h.key
  end, hits)
  eq(keys, {
    "common.title",
    "common.actions.save",
    "home.title",
    "missing.key",
    "common.actions.cancel",
    "common.title",
  })
end)

test("scanner reports 0-based key columns and the call end", function()
  local compiled = scanner.compile({ "t" })
  local hit = scanner.scan({ "x = t('a.b') + 1" }, compiled, 4)[1]
  eq({ hit.lnum, hit.col, hit.end_col, hit.call_end }, { 4, 7, 10, 11 })
end)

test("scanner accepts custom Lua patterns", function()
  local compiled = scanner.compile({}, { 'i18nKey="([^"]+)"' })
  local hit = scanner.scan({ '<Trans i18nKey="welcome.title" />' }, compiled, 0)[1]
  eq({ hit.key, hit.col }, { "welcome.title", 16 })
end)

test("completion context only inside a translation call", function()
  local fns = config.defaults.functions
  eq(scanner.context("const a = t('common.ac", fns), { start = 13, prefix = "common.ac" })
  eq(scanner.context('const a = $t("', fns), { start = 14, prefix = "" })
  eq(scanner.context("const a = test('x", fns), nil)
  eq(scanner.context("const a = t('done') + 1", fns), nil)
end)

-- edit

local base = {
  "{",
  '  "common": {',
  '    "title": "Title"',
  "  },",
  '  "empty": {},',
  '  "last": "Last"',
  "}",
}

test("insert adds a sibling and fixes the previous comma", function()
  local out = assert(edit.insert(base, "common.subtitle", "Sub"))
  eq(vim.list_slice(out, 2, 5), { '  "common": {', '    "title": "Title",', '    "subtitle": "Sub"', "  }," })
end)

test("insert creates missing nested objects at the root", function()
  local out = assert(edit.insert(base, "new.deep.key", 'Say "hi"'))
  eq(vim.list_slice(out, 6, 12), {
    '  "last": "Last",',
    '  "new": {',
    '    "deep": {',
    '      "key": "Say \\"hi\\""',
    "    }",
    "  }",
    "}",
  })
end)

test("insert opens a one-line empty object", function()
  local out = assert(edit.insert(base, "empty.child", "C"))
  eq(vim.list_slice(out, 5, 7), { '  "empty": {', '    "child": "C"', "  }," })
end)

test("insert refuses existing keys and keys under a value", function()
  eq(select(2, edit.insert(base, "common.title", "x")), "key already exists")
  eq(select(2, edit.insert(base, "last.child", "x")), "'last' is a value, not an object")
end)

test("insert detects tab indentation", function()
  local out = assert(edit.insert({ "{", '\t"a": "A"', "}" }, "b", "B"))
  eq(out, { "{", '\t"a": "A",', '\t"b": "B"', "}" })
end)

test("add writes every locale file and reloads the store", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/locales", "p")
  vim.fn.writefile({ "{}" }, tmp .. "/package.json")
  vim.fn.writefile({ "{", '  "a": "A"', "}" }, tmp .. "/locales/en.json")
  vim.fn.writefile({ "{", '  "a": "A fr"', "}" }, tmp .. "/locales/fr.json")
  config.setup({ root_markers = { "package.json" } })
  local store = store_mod.new(tmp, (config.for_root(tmp)))
  store:ensure("fr")
  local written, errors = edit.add(store, "b.c", { en = "BC", fr = "BC fr" })
  eq(#written, 2)
  eq(errors, {})
  eq(store:get("b.c", "fr"), "BC fr")
  eq(read(tmp .. "/locales/en.json"), { "{", '  "a": "A",', '  "b": {', '    "c": "BC"', "  }", "}", "" })
  vim.fn.delete(tmp, "rf")
end)

-- usages

test("usages parses rg --json matches", function()
  local line = vim.json.encode({
    type = "match",
    data = {
      path = { text = "./src/App.vue" },
      lines = { text = "  t('a.b')\n" },
      line_number = 7,
      submatches = { { start = 4 } },
    },
  })
  eq(usages.parse(line .. "\n" .. '{"type":"begin"}'), {
    { file = "./src/App.vue", line = 7, col = 5, text = "t('a.b')" },
  })
end)

print(("\n%d tests, %d failure(s)"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
