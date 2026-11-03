local M = {}

local groups = {
  a = "àáâãäåāăą",
  A = "ÀÁÂÃÄÅĀĂĄ",
  c = "çćĉċč",
  C = "ÇĆĈĊČ",
  d = "ďđ",
  D = "ĎĐ",
  e = "èéêëēĕėęě",
  E = "ÈÉÊËĒĔĖĘĚ",
  g = "ĝğġģ",
  G = "ĜĞĠĢ",
  h = "ĥħ",
  H = "ĤĦ",
  i = "ìíîïĩīĭįı",
  I = "ÌÍÎÏĨĪĬĮİ",
  j = "ĵ",
  J = "Ĵ",
  k = "ķ",
  K = "Ķ",
  l = "ĺļľŀł",
  L = "ĹĻĽĿŁ",
  n = "ñńņňŉ",
  N = "ÑŃŅŇ",
  o = "òóôõöøōŏő",
  O = "ÒÓÔÕÖØŌŎŐ",
  r = "ŕŗř",
  R = "ŔŖŘ",
  s = "śŝşš",
  S = "ŚŜŞŠ",
  t = "ţťŧ",
  T = "ŢŤŦ",
  u = "ùúûüũūŭůűų",
  U = "ÙÚÛÜŨŪŬŮŰŲ",
  w = "ŵ",
  W = "Ŵ",
  y = "ýÿŷ",
  Y = "ÝŸŶ",
  z = "źżž",
  Z = "ŹŻŽ",
  ae = "æ",
  AE = "Æ",
  oe = "œ",
  OE = "Œ",
  ss = "ß",
}

local map = {}
for base, chars in pairs(groups) do
  for _, ch in ipairs(vim.fn.split(chars, "\\zs")) do
    map[ch] = base
  end
end

--- Lowercases `s` and strips the accents of Latin letters, so "Créer" and "CRÉER" both give "creer".
function M.fold(s)
  return (s:gsub("[\192-\244][\128-\191]*", map):lower())
end

return M
