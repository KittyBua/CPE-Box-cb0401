package main

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ------------------------------------------------------- SMS on the SIM ---
// The stock mobile daemon reads from the modem's own flash (CPMS="ME"), which
// is where incoming SMS land by default on cb0401. Nothing there reads what's
// sitting on the SIM card itself (CPMS="SM"). Some carriers / older messages
// end up there instead - the panel didn't see them.
//
// This reads the SIM storage over AT directly: switches CPMS to SM, lists
// everything in UCS2 (so umlauts / Cyrillic survive), parses the +CMGL
// multi-line blocks, then restores CPMS to ME so the stock daemon keeps
// working. The result is shaped like one `msgbox` entry from the stock SMS
// API so the Messages page can merge the two lists without caring where
// each row came from.

var (
	cmglRe = regexp.MustCompile(`\+CMGL:\s*(\d+),"([^"]*)","([^"]*)"(?:,"([^"]*)")?,"([^"]*)"`)
)

// cmglStat maps the <stat> text to the state bits the stock SMS JSON uses:
// bit3 (8) = received, bit2 (4) = sent, bit1 (2) = draft, bit0 (1) = read.
func cmglStat(stat string) int {
	switch strings.ToUpper(strings.TrimSpace(stat)) {
	case "REC UNREAD":
		return 8
	case "REC READ":
		return 8 | 1
	case "STO UNSENT":
		return 2
	case "STO SENT":
		return 4
	}
	return 0
}

// parseCMGL parses an "AT+CMGL=\"ALL\"" reply where the modem returned UCS2
// (set with AT+CSCS="UCS2"). Each message is two lines: a +CMGL header, then
// the body. "contact_phone_b64" is sent back to the stock endpoints for the
// "delete" / "reply" path, so the field layout matches the stock msgbox row.
func parseCMGL(raw string) []map[string]any {
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	var out []map[string]any
	for i := 0; i < len(lines); i++ {
		m := cmglRe.FindStringSubmatch(lines[i])
		if m == nil {
			continue
		}
		body := ""
		if i+1 < len(lines) {
			body = ucs2Decode(strings.TrimSpace(lines[i+1]))
			i++
		}
		id, _ := strconv.Atoi(m[1])
		sender := ucs2Decode(m[3])
		scts := strings.TrimSpace(m[5])
		ts := parseCMGLDate(scts)
		row := map[string]any{
			"msg_id":            id,
			"state":             cmglStat(m[2]),
			"contact_phone":     sender,
			"contact_phone_b64": base64.StdEncoding.EncodeToString([]byte(sender)),
			"content":           body,
			"date":              scts,
			"timestamp":         ts,
			"storage":           "SM",
		}
		out = append(out, row)
	}
	return out
}

// parseCMGLDate turns an SCTS timestamp ("yy/MM/dd,hh:mm:ss+tz") into unix
// seconds. The timezone is in 15-minute units per 3GPP TS 23.040; we take it
// into account so a message from a different zone sorts right in the thread.
func parseCMGLDate(s string) int64 {
	s = strings.TrimSpace(s)
	if len(s) < 17 {
		return 0
	}
	t, err := time.Parse("06/01/02,15:04:05", s[:17])
	if err != nil {
		return 0
	}
	if len(s) > 17 {
		sign, tz := byte('+'), 0
		rest := s[17:]
		if rest[0] == '+' || rest[0] == '-' {
			sign = rest[0]
			rest = rest[1:]
		}
		tz, _ = strconv.Atoi(rest)
		off := time.Duration(tz) * 15 * time.Minute
		if sign == '-' {
			off = -off
		}
		t = t.Add(-off)
	}
	return t.Unix()
}

// readSIMSMS lists what's on the SIM. Returns [] when the storage is empty.
// atQuery serializes with the stock daemon via /var/lock/LCK..ttyUSB2, and
// CPMS is restored to ME before this function returns, so refreshMsgbox stays
// pointing at the modem flash it was polling before.
func readSIMSMS() ([]map[string]any, error) {
	// First find out how many SMS the SIM can hold - skip the AT roundtrip
	// entirely when the storage is empty.
	raw, err := atQuery([]string{
		`AT+CPMS="SM"`,
	}, 800*time.Millisecond)
	if err != nil {
		return nil, err
	}
	used := 0
	if m := regexp.MustCompile(`\+CPMS:\s*(\d+),\d+`).FindStringSubmatch(raw); m != nil {
		used, _ = strconv.Atoi(m[1])
	}
	defer func() {
		// Restore storage + charset so refreshMsgbox (ME) and other AT users
		// aren't surprised. Best-effort: a modem reset would also reset these.
		_, _ = atQuery([]string{`AT+CSCS="GSM"`, `AT+CPMS="ME"`}, 600*time.Millisecond)
	}()
	if used == 0 {
		return []map[string]any{}, nil
	}
	raw, err = atQuery([]string{
		`AT+CMGF=1`,
		`AT+CSCS="UCS2"`,
		`AT+CMGL="ALL"`,
	}, 1500*time.Millisecond)
	if err != nil {
		return nil, err
	}
	return parseCMGL(raw), nil
}

// deleteSIMSMS removes one message from the SIM. The stock delete path only
// knows the modem's own storage; this one goes straight through AT.
func deleteSIMSMS(index int) error {
	if index <= 0 {
		return routerErrf("Bad SIM SMS index %d", index)
	}
	raw, err := atQuery([]string{
		`AT+CPMS="SM"`,
		fmt.Sprintf(`AT+CMGD=%d`, index),
		`AT+CPMS="ME"`,
	}, 1000*time.Millisecond)
	if err != nil {
		return err
	}
	if strings.Contains(raw, "ERROR") {
		return routerErrf("Modem refused to delete SMS %d: %s", index, strings.TrimSpace(raw))
	}
	return nil
}
