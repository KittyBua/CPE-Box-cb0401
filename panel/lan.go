package main

import (
	"fmt"
	"log"
	"net"
	"regexp"
	"strings"
	"time"
)

var hostnameRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)

// lanHostname is the name the router's DNS answers with this machine's
// address, so the panel opens at http://cpe.box:7777 from any device on the
// network (GUI_HOSTNAME overrides it). cpe.lan is registered as well: .lan is
// the router's own local zone (dnsmasq local=/lan/), so it keeps working even
// if the public .box name ever got registered by someone.
func lanHostname() string {
	h := strings.ToLower(getenv("GUI_HOSTNAME", "cpe.box"))
	if !hostnameRe.MatchString(h) {
		return "cpe.box"
	}
	return h
}

func lanHostnames() []string {
	if h := lanHostname(); h != "cpe.lan" {
		return []string{h, "cpe.lan"}
	}
	return []string{"cpe.lan"}
}

// localIPTowardRouter is this machine's address on the router's network -
// the source address the OS would use to reach it (no packet is sent).
func localIPTowardRouter() (string, error) {
	c, err := net.Dial("udp", net.JoinHostPort(routerIP, "53"))
	if err != nil {
		return "", err
	}
	defer c.Close()
	ip := c.LocalAddr().(*net.UDPAddr).IP.To4()
	if ip == nil || ip.IsLoopback() {
		return "", fmt.Errorf("no IPv4 route to the router")
	}
	return ip.String(), nil
}

// registerLanHostname points <hostname> at ip in the router's dnsmasq (UCI
// dhcp, persisted in /data like everything else setup configures there),
// replacing any earlier address for the same name. No-op if already set.
func registerLanHostname(host, ip string) (bool, error) {
	script := fmt.Sprintf(`H=%s; WANT="/$H/%s"
CUR=$(uci -q get dhcp.@dnsmasq[0].address)
case " $CUR " in *" $WANT "*) case " $CUR " in *"/tune.lan/"*) ;; *) echo SAME; exit 0;; esac;; esac
for a in $CUR; do case "$a" in "/$H/"*|"/tune.lan/"*) uci del_list dhcp.@dnsmasq[0].address="$a";; esac; done
uci add_list dhcp.@dnsmasq[0].address="$WANT" && uci commit dhcp
/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
echo CHANGED`, host, ip)
	out, err := run(script, 20*time.Second)
	if err != nil {
		return false, err
	}
	return strings.Contains(out, "CHANGED"), nil
}

// keepLanHostnameCurrent registers the name now and re-checks every few
// minutes, since this machine's DHCP address can change.
func keepLanHostnameCurrent() {
	last := ""
	for {
		if ip, err := localIPTowardRouter(); err == nil && ip != last {
			okAll := true
			for _, host := range lanHostnames() {
				changed, err := registerLanHostname(host, ip)
				if err != nil {
					log.Printf("registering %s: %v", host, err)
					okAll = false
				} else if changed {
					log.Printf("%s now points to %s", host, ip)
				}
			}
			if okAll {
				last = ip
			}
		}
		time.Sleep(5 * time.Minute)
	}
}
