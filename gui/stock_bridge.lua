-- cpe-box stock bridge: runs one action of the stock Xiaomi web UI
-- (luci.controller.api.<module>.<function>) with the given form fields and
-- prints its JSON answer, exactly as the stock web page would get it - but
-- without the web login, since cpe-box already runs as root over SSH.
--
-- usage: lua stock_bridge.lua <module> <function> <base64 JSON of form fields>
local J = require("cjson")
local http = require("luci.http")
local nixio = require("nixio")

local fields = {}
if arg[3] and arg[3] ~= "" then
  local raw = nixio.bin.b64decode(arg[3])
  fields = raw and J.decode(raw) or {}
end
-- "<name>_b64" carries exact bytes (e.g. an SMS sender whose name isn't
-- valid UTF-8, which JSON would mangle) - decode it back into <name>.
local raw_fields = {}
for k, v in pairs(fields) do
  local base = type(k) == "string" and k:match("^(.+)_b64$")
  if base and type(v) == "string" then raw_fields[base] = nixio.bin.b64decode(v) end
end
for k, v in pairs(raw_fields) do fields[k] = v end

-- ...and the other way: senders go out with their raw bytes alongside.
local function add_raw(t, depth)
  if type(t) ~= "table" or depth > 6 then return end
  if type(t.contact_phone) == "string" then t.contact_phone_b64 = nixio.bin.b64encode(t.contact_phone) end
  for _, v in pairs(t) do add_raw(v, depth + 1) end
end

-- the stock pages get these from the web template environment
_G._ = _G._ or function(s) return s end
_G.translate = _G.translate or function(s) return s end
_G.translatef = _G.translatef or function(s, ...) return string.format(s, ...) end

local out
http.formvalue = function(name)
  if name == nil then return fields end
  local v = fields[name]
  if v == nil or v == J.null then return nil end
  return tostring(v)
end
http.formvaluetable = function(prefix)
  local t = {}
  for k, v in pairs(fields) do
    if k:sub(1, #prefix + 1) == prefix .. "." then t[k:sub(#prefix + 2)] = tostring(v) end
  end
  return t
end
http.write_json = function(v) out = v end
http.write = function(v) if out == nil then out = v end end
http.prepare_content = function() end
http.header = function() end
http.status = function() end
http.getenv = function() return nil end
http.redirect = function() end

local ok, t = pcall(require, "luci.controller.api." .. arg[1])
if not ok or type(t) ~= "table" or type(t[arg[2]]) ~= "function" then
  io.write(J.encode({ code = -1, msg = "no such stock action: " .. tostring(arg[1]) .. "." .. tostring(arg[2]) }))
  return
end
local ok2, err = pcall(t[arg[2]])
if not ok2 and out == nil then
  io.write(J.encode({ code = -1, msg = tostring(err) }))
  return
end
if type(out) == "table" then
  add_raw(out, 0)
  io.write(J.encode(out))
else
  io.write(tostring(out or J.encode({ code = 0 })))
end
