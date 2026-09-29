package main

import (
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

// The stock Xiaomi web UI's own actions (Wi-Fi name/password, APN, SIM PIN,
// SMS, LAN/DHCP, address reservations, port forwarding, ...), run on the
// router through stock_bridge.lua. Going through Xiaomi's own code keeps
// every side effect it has (service restarts, the settings sync the stock
// daemons rely on) instead of re-implementing them with raw uci writes.

//go:embed stock_bridge.lua
var stockBridge []byte

var stockBridgePath = func() string {
	sum := sha256.Sum256(stockBridge)
	return "/tmp/cpebox_stock_" + hex.EncodeToString(sum[:4]) + ".lua"
}()

type stockAction struct {
	mod, fn     string
	write       bool
	timeout     time.Duration
	invalidates []string // cache keys (reads are cached as "stock:<name>")
}

// Only these actions are exposed. Reads are GET, writes POST; each maps to
// luci.controller.api.<mod>.<fn> with the stock web page's field names.
var stockActions = map[string]stockAction{
	// reads
	"wifi":       {mod: "xqnetwork", fn: "getAllWifiInfo"},
	"lan":        {mod: "xqnetwork", fn: "getLanInfo"},
	"dhcp":       {mod: "xqnetwork", fn: "getLanDhcp"},
	"hosts":      {mod: "xqnetwork", fn: "getMacBindInfo"},
	"apn":        {mod: "xqmobile", fn: "GetApnInfo"},
	"netcfg":     {mod: "xqmobile", fn: "GetMobileNetCfg"},
	"pin":        {mod: "xqmobile", fn: "GetRetryCount"},
	"autopin":    {mod: "xqmobile", fn: "GetAutoPin"},
	"sms":        {mod: "xqmobile", fn: "refreshMsgbox"},
	"sms_thread": {mod: "xqmobile", fn: "getDialogMsg", invalidates: []string{"stock:sms"}}, // marks the thread read
	"dmz":        {mod: "xqsystem", fn: "getDMZInfo"},
	"portfwd":    {mod: "xqsystem", fn: "get_vs_rules"},
	"upnp":       {mod: "xqsystem", fn: "upnpList"},
	"time":       {mod: "misystem", fn: "getSysTime"},
	"name":       {mod: "misystem", fn: "getRouterName"},

	// writes
	"wifi_set":   {mod: "xqnetwork", fn: "setWifi", write: true, timeout: 60 * time.Second, invalidates: []string{"stock:wifi", "status"}},
	"wifi_on":    {mod: "xqnetwork", fn: "turnOnWifi", write: true, timeout: 60 * time.Second, invalidates: []string{"stock:wifi", "status"}},
	"wifi_off":   {mod: "xqnetwork", fn: "shutDownWifi", write: true, timeout: 60 * time.Second, invalidates: []string{"stock:wifi", "status"}},
	"lan_ip":     {mod: "xqnetwork", fn: "setLanIp", write: true, invalidates: []string{"stock:lan", "stock:dhcp"}},
	"dhcp_set":   {mod: "xqnetwork", fn: "setLanDhcp", write: true, invalidates: []string{"stock:dhcp"}},
	"bind":       {mod: "xqnetwork", fn: "macBind", write: true, invalidates: []string{"stock:hosts"}},
	"unbind":     {mod: "xqnetwork", fn: "macUnbind", write: true, invalidates: []string{"stock:hosts"}},
	"rename":     {mod: "xqsystem", fn: "setDeviceNickName", write: true, invalidates: []string{"stock:hosts"}},
	"access":     {mod: "xqsystem", fn: "setMacFilter", write: true, invalidates: []string{"stock:hosts"}},
	"netcfg_set": {mod: "xqmobile", fn: "SetMobileNetCfg", write: true, timeout: 45 * time.Second, invalidates: []string{"stock:netcfg", "cellular"}},
	"apn_save":   {mod: "xqmobile", fn: "SaveApnFile", write: true, invalidates: []string{"stock:apn"}},
	"apn_apply":  {mod: "xqmobile", fn: "ApplyApnFile", write: true, timeout: 45 * time.Second, invalidates: []string{"stock:apn", "cellular"}},
	"apn_delete": {mod: "xqmobile", fn: "DelApnFile", write: true, invalidates: []string{"stock:apn"}},
	"pin_lock":   {mod: "xqmobile", fn: "SwitchPinLock", write: true, invalidates: []string{"stock:pin", "cellular"}},
	"pin_change": {mod: "xqmobile", fn: "ModifySIMPin", write: true, invalidates: []string{"stock:pin"}},
	// Verify/enter the SIM PIN (unlocks the SIM after a reboot when auto-pin is off,
	// or when the stored auto-pin was wrong). Body: {"sim_pin":"1234"}.
	"pin_verify": {mod: "xqmobile", fn: "CheckSIMPin", write: true, timeout: 30 * time.Second, invalidates: []string{"stock:pin", "cellular", "status"}},
	// Unblock the SIM with the PUK after too many wrong PINs, and set a new PIN
	// at the same time. Body: {"sim_puk":"12345678","sim_pin":"5678"}.
	"puk_verify":  {mod: "xqmobile", fn: "CheckSIMPuk", write: true, timeout: 30 * time.Second, invalidates: []string{"stock:pin", "cellular", "status"}},
	"autopin_set": {mod: "xqmobile", fn: "SetAutoPin", write: true, invalidates: []string{"stock:autopin"}},
	"sms_send":    {mod: "xqmobile", fn: "sendMsg", write: true, timeout: 45 * time.Second, invalidates: []string{"stock:sms", "stock:sms_thread"}},
	"sms_delete":  {mod: "xqmobile", fn: "deleteMsgDialog", write: true, invalidates: []string{"stock:sms", "stock:sms_thread"}},
	"dmz_set":     {mod: "xqsystem", fn: "setDMZ", write: true, invalidates: []string{"stock:dmz"}},
	"dmz_off":     {mod: "xqsystem", fn: "closeDMZ", write: true, invalidates: []string{"stock:dmz"}},
	"portfwd_add": {mod: "xqsystem", fn: "set_vs_rules", write: true, invalidates: []string{"stock:portfwd"}},
	"portfwd_del": {mod: "xqsystem", fn: "del_vs_rules", write: true, invalidates: []string{"stock:portfwd"}},
	"upnp_set":    {mod: "xqsystem", fn: "upnpSwitch", write: true, invalidates: []string{"stock:upnp"}},
	"name_set":    {mod: "misystem", fn: "setRouterName", write: true, invalidates: []string{"stock:name"}},
}

// stockCall runs one stock action and returns its JSON answer. A nonzero
// "code" in the answer is the stock UI's own error and comes back as one.
func stockCall(a stockAction, fields map[string]string, timeout time.Duration) (map[string]any, error) {
	fj, _ := json.Marshal(fields)
	cmd := fmt.Sprintf(`F=%s; [ -f $F ] || { rm -f /tmp/cpebox_stock_*.lua; echo %s | base64 -d > $F; }; lua $F %s %s %s`,
		stockBridgePath, base64.StdEncoding.EncodeToString(stockBridge), a.mod, a.fn, base64.StdEncoding.EncodeToString(fj))
	out, err := run(cmd, timeout)
	if err != nil {
		return nil, err
	}
	// Some stock actions print stray output (e.g. "true") before their JSON.
	out = strings.TrimSpace(out)
	var res map[string]any
	for i := strings.IndexByte(out, '{'); ; {
		if i < 0 {
			return nil, routerErrf("Unexpected answer from the router: %.200s", out)
		}
		if json.Unmarshal([]byte(out[i:]), &res) == nil {
			break
		}
		j := strings.IndexByte(out[i+1:], '{')
		if j < 0 {
			i = -1
		} else {
			i += j + 1
		}
	}
	if code, ok := res["code"].(float64); ok && code != 0 {
		msg, _ := res["msg"].(string)
		if msg == "" {
			msg = fmt.Sprintf("the router refused the change (code %d)", int(code))
		}
		return nil, routerErrf("%s", msg)
	}
	return res, nil
}

func handleStock(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("a")
	a, found := stockActions[name]
	if !found {
		http.NotFound(w, r)
		return
	}
	fields := map[string]string{}
	if a.write {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body map[string]any
		decodeBody(r, &body)
		for k, v := range body {
			fields[k] = anyToStr(v)
		}
		timeout := a.timeout
		if timeout == 0 {
			timeout = 30 * time.Second
		}
		res, err := stockCall(a, fields, timeout)
		invalidate(a.invalidates...)
		if err != nil {
			errResp(w, err)
			return
		}
		ok(w, res)
		return
	}
	var keys []string
	for k, v := range r.URL.Query() {
		if k != "a" && len(v) > 0 {
			fields[k] = v[0]
			keys = append(keys, k+"="+v[0])
		}
	}
	sort.Strings(keys)
	cacheKey := "stock:" + name
	if len(keys) > 0 {
		cacheKey += "?" + strings.Join(keys, "&")
	}
	ttl := 15 * time.Second
	if len(a.invalidates) > 0 {
		ttl = 0 // a read with side effects is never served from cache
	}
	res, err := cached(cacheKey, ttl, func() (any, error) { return stockCall(a, fields, 30*time.Second) })
	invalidate(a.invalidates...)
	if err != nil {
		errResp(w, err)
		return
	}
	ok(w, res)
}
