package main

import "testing"

// Real AT reply block captured from the RG520N-EB modem (LTE + NR5G NSA on
// Telekom.de). The AT fallback must reconstruct the same essentials the stock
// daemon's dump_status would have returned.
const sampleAT = "AT+COPS?\r\n+COPS: 0,0,\"Telekom.de\",13\r\n\r\nOK\r\n" +
	"AT+QNWINFO\r\n+QNWINFO: \"FDD LTE\",\"26201\",\"LTE BAND 3\",1300\r\n" +
	"+QNWINFO: \"FDD NR5G\",\"26201\",\"NR5G BAND 1\",431070\r\n\r\nOK\r\n" +
	"AT+QENG=\"servingcell\"\r\n+QENG: \"servingcell\",\"NOCONN\"\r\n" +
	"+QENG: \"LTE\",\"FDD\",262,01,1929500,321,1300,3,5,5,34BA,-75,-7,-48,25,15,100,-\r\n" +
	"+QENG: \"NR5G-NSA\",262,01,774,-82,30,-11,431070,1,3,0\r\n\r\nOK\r\n" +
	"AT+CPIN?\r\n+CPIN: READY\r\n\r\nOK\r\n" +
	"AT+CEREG?\r\n+CEREG: 0,1\r\n\r\nOK\r\n" +
	"AT+QCCID\r\n+QCCID: 89490200002149039092\r\n\r\nOK\r\n" +
	"AT+CNUM\r\n+CNUM: ,\"+4917684249486\",145\r\n\r\nOK\r\n" +
	"AT+CGDCONT?\r\n+CGDCONT: 1,\"IPV4V6\",\"internet.v6.telekom\",\"0.0.0.0\",0,0\r\n\r\nOK\r\n"

func TestParseATCellular(t *testing.T) {
	info := parseATCellular(sampleAT)
	wantStr := map[string]string{
		"operator":     "Telekom.de",
		"network_type": "5G NSA",
		"band_primary": "B3",
		"band_5g":      "n1",
		"apn":          "internet.v6.telekom",
		"rsrp":         "-75",
		"rsrq":         "-7",
		"rssi":         "-48",
		"snr":          "25",
		"pci":          "321",
		"rsrp_5g":      "-82",
		"snr_5g":       "30",
		"rsrq_5g":      "-11",
		"pci_5g":       "774",
		"sim_status":   "Ready",
		"sim_number":   "+4917684249486",
		"sim_iccid":    "89490200002149039092",
	}
	for k, want := range wantStr {
		if got, _ := info[k].(string); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
	if info["registered"] != true {
		t.Errorf("registered = %v, want true", info["registered"])
	}
	if info["roaming"] != false {
		t.Errorf("roaming = %v, want false", info["roaming"])
	}
	if info["level"] != 5 { // rsrp -75 -> 5 bars
		t.Errorf("level = %v, want 5", info["level"])
	}
}

// Real dump_status from the stock daemon on cb0401 v2 (ROM 3.0.57). Signal
// fields are quoted strings and ci_5g is the "-" placeholder that used to
// break a json.Number parse — parseDumpStatus (via loose) must handle both.
const sampleDump = `{"sim":{"status":1,"pin_remains":3,"puk_remains":10,"lock":1,"iccid":"89490200002149039092","imsi":"262011628009544","number":"+4917684249486","country":"DE"},"status":{"registration":1,"isp":"Telekom.de","apn":"internet.v6.telekom","rat":"5G NSA","band":"B3+B8+n1","roam":0,"cell_band":"B3(FDD 1800+)","ci":"26383616","pci":"321","level":4,"rsrq":"-7.0","rsrp":"-75.4","snr":"28.0","rssi":"-48.4","cell_band_5g":"n1(FDD 2100)","ci_5g":"-","pci_5g":"774","rsrq_5g":"-11.0","rsrp_5g":"-83.0","snr_5g":"28.0"},"code":0}`

func TestParseDumpStatus(t *testing.T) {
	info, err := parseDumpStatus(sampleDump)
	if err != nil {
		t.Fatalf("parseDumpStatus errored: %v", err)
	}
	want := map[string]any{
		"operator": "Telekom.de", "network_type": "5G NSA",
		"rsrp": "-75.4", "rsrp_5g": "-83.0", "pci": "321", "pci_5g": "774",
		"sim_status": "Ready", "level": 4, "registered": true, "roaming": false,
		"sim_locked": true,
	}
	for k, v := range want {
		if info[k] != v {
			t.Errorf("%s = %v, want %v", k, info[k], v)
		}
	}
}

// loose must accept a quoted string, a bare number, and the "-" placeholder
// without ever failing the surrounding parse.
func TestLooseUnmarshal(t *testing.T) {
	cases := map[string]string{
		`"-77.0"`: "-77.0",
		`-77.0`:   "-77.0",
		`-77`:     "-77",
		`"-"`:     "-",
		`""`:      "",
		`null`:    "",
	}
	for in, want := range cases {
		var l loose
		if err := l.UnmarshalJSON([]byte(in)); err != nil {
			t.Errorf("UnmarshalJSON(%s) errored: %v", in, err)
			continue
		}
		if l.String() != want {
			t.Errorf("UnmarshalJSON(%s) = %q, want %q", in, l.String(), want)
		}
	}
}
