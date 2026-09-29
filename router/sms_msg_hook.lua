-- CPE Box: stands in for /usr/sbin/sms_msg.lua (bind-mounted by
-- sms_notify.sh --hook). Runs the stock SMS handler first, unchanged, then
-- forwards the new message.
local q = {}
for i = 1, #arg do
    q[#q + 1] = "'" .. (tostring(arg[i]):gsub("'", "'\\''")) .. "'"
end
os.execute("/usr/bin/lua /tmp/sms_msg_stock.lua " .. table.concat(q, " "))
os.execute("sh /etc/crontabs/patches/sms_notify.sh >/dev/null 2>&1")
