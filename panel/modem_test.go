package main

import (
	"encoding/hex"
	"reflect"
	"testing"
)

// Captured live from an RG520N on Telekom.de (5G NSA, B3 anchor + B8 + n1).
const capturedLockReply = `AT+QNWLOCK="common/4g"
+CME ERROR: 904
AT+QNWLOCK="common/5g"
+CME ERROR: 904
AT+QNWLOCK="save_ctrl"
+QNWLOCK: "save_ctrl",0,0

OK
AT+QENG="servingcell"
+QENG: "servingcell","NOCONN"
+QENG: "LTE","FDD",262,01,1929500,321,1300,3,5,5,34BA,-75,-8,-50,24,12,120,-
+QENG: "NR5G-NSA",262,01,774,-82,30,-11,431070,1,3,0

OK
AT+QCAINFO
+QCAINFO: "PCC",1300,100,"LTE BAND 3",1,321,-75,-8,-47,30
+QCAINFO: "SCC",3749,50,"LTE BAND 8",1,225,-101,-11,-80,4,0,-,-
+QCAINFO: "SCC",431070,3,"NR5G BAND 1",774

OK
AT+QENG="neighbourcell"
+QENG: "neighbourcell intra","LTE",1300,321,-7,-74,-46,-,-,-,-,-,-
+QENG: "neighbourcell inter","LTE",3749,225,-10,-98,-71,-,-,-,-,-
+QENG: "neighbourcell inter","LTE",3749,43,-12,-102,-77,-,-,-,-,-

OK
AT+QNWCFG="nr5g_meas_info"
+QNWCFG: "nr5g_meas_info",1,431070,774,-86,-11,431070,12,-101,-15

OK
`

func TestParseCellLockUnlocked(t *testing.T) {
	got := parseCellLock(capturedLockReply)
	if l := got["lte"].([]lteCell); len(l) != 0 {
		t.Errorf("lte = %v, want none", l)
	}
	if got["nr"] != nil || got["persist"] != false {
		t.Errorf("nr/persist = %v/%v, want nil/false", got["nr"], got["persist"])
	}
	if s := got["serving_lte"]; s != (lteCell{1300, 321}) {
		t.Errorf("serving_lte = %v", s)
	}
	if s := got["serving_nr"]; s != (nrCell{PCI: 774, Arfcn: 431070, SCS: 15, Band: 1}) {
		t.Errorf("serving_nr = %v", s)
	}
	car := got["carriers"].([]radioCell)
	if len(car) != 3 || car[0].Band != "B3" || car[1].Band != "B8" || car[1].PCI != 225 || car[2].Band != "n1" || car[2].PCI != 774 {
		t.Errorf("carriers = %+v", car)
	}
	if car[2].RSRP != "-86" || car[2].RSRQ != "-11" {
		t.Errorf("NSA leg signal not filled from the NR report: %+v", car[2])
	}
	if car[0].RSSI != "-47" || car[0].SINR != "30" {
		t.Errorf("PCC signal = %+v", car[0])
	}
	n := got["neighbours"].([]radioCell)
	if len(n) != 5 {
		t.Fatalf("neighbours = %+v", n)
	}
	// LTE neighbour fields: RSRQ comes before RSRP in the modem's reply
	if n[1].Band != "B8" || n[1].PCI != 225 || n[1].RSRP != "-98" || n[1].RSRQ != "-10" || !n[1].Serving {
		t.Errorf("LTE neighbour = %+v", n[1])
	}
	if !n[0].Serving || n[2].Serving {
		t.Errorf("serving marks = %v / %v", n[0].Serving, n[2].Serving)
	}
	if n[3].RAT != "NR" || !n[3].Serving || n[4].PCI != 12 || n[4].Band != "n1" || n[4].RSRP != "-101" || n[4].Key != "nr:431070:12" {
		t.Errorf("NR neighbours = %+v / %+v", n[3], n[4])
	}
}

// cb0401 v1 (issue #1): QENG reports the NR leg with PCI 0 and band 0; the
// lock form must take the real PCI from QCAINFO instead.
func TestParseCellLockV1UsesQCAINFO(t *testing.T) {
	raw := `+QENG: "LTE","FDD",226,01,307758,459,2850,7,5,5,BDC,-111,-11,-77,10,0,-,-
+QENG: "NR5G-NSA",226,01,0,-94,21,-11,423130,0,3,0
+QCAINFO: "PCC",2850,100,"LTE BAND 7",1,459,-111,-11,-77,10
+QCAINFO: "SCC",1451,100,"LTE BAND 3",1,459,-97,-11,-67,8,0,-,-
+QCAINFO: "SCC",423130,3,"NR5G BAND 0",459
`
	got := parseCellLock(raw)
	if s := got["serving_lte"]; s != (lteCell{2850, 459}) {
		t.Errorf("serving_lte = %v", s)
	}
	if s := got["serving_nr"]; s != (nrCell{PCI: 459, Arfcn: 423130, SCS: 15, Band: 1}) {
		t.Errorf("serving_nr = %v, want PCI 459 n1", s)
	}
}

func TestParseCellLockLocked(t *testing.T) {
	raw := `+QNWLOCK: "common/4g",2,1300,321,6300,12
+QNWLOCK: "common/5g",774,431070,15,1
+QNWLOCK: "save_ctrl",1,1
`
	got := parseCellLock(raw)
	if l := got["lte"]; !reflect.DeepEqual(l, []lteCell{{1300, 321}, {6300, 12}}) {
		t.Errorf("lte = %v", l)
	}
	if n := got["nr"]; n != (nrCell{774, 431070, 15, 1}) {
		t.Errorf("nr = %v", n)
	}
	if got["persist"] != true {
		t.Errorf("persist = %v", got["persist"])
	}
}

func TestParseCellLockSA(t *testing.T) {
	raw := `+QENG: "servingcell","NOCONN","NR5G-SA","TDD",262,01,1A2B3C,512,ABCD,643296,78,12,-90,-11,18,1,-
`
	if s := parseCellLock(raw)["serving_nr"]; s != (nrCell{512, 643296, 30, 78}) {
		t.Errorf("serving_nr = %v", s)
	}
}

func TestLteBandFromEarfcn(t *testing.T) {
	for e, want := range map[int]string{1300: "B3", 3749: "B8", 2850: "B7", 6300: "B20", 9999999: ""} {
		if got := lteBandFromEarfcn(e); got != want {
			t.Errorf("%d -> %q, want %q", e, got, want)
		}
	}
}

func TestEncodeMSISDN(t *testing.T) {
	// The record as read back from a real Telekom SIM (AT+CRSM=178,28480,1,4,0).
	const real = "456967656E65205275666E756D6D65720891947186249484F6FFFFFFFFFF"
	alpha, _ := hex.DecodeString(real[:32])
	got, err := encodeMSISDN("+4917684249486", 30, alpha)
	if err != nil || got != real {
		t.Errorf("encode = %s, %v\nwant     %s", got, err, real)
	}
	// Even digit count, national number, no alpha tag.
	got, _ = encodeMSISDN("0601234567", 14, nil)
	if want := "06816010325476FFFFFFFFFFFFFF"; got != want {
		t.Errorf("encode = %s, want %s", got, want)
	}
}

func TestFcpRecordLength(t *testing.T) {
	m := fcpRecLenRe.FindStringSubmatch("621E82054221001E0483026F40A5038001618A01058B036F060F800200788800")
	if m == nil || m[1] != "001E" {
		t.Errorf("record length = %v, want 001E", m)
	}
}

func TestDiagHost(t *testing.T) {
	for _, h := range []string{"8.8.8.8", "one.one.one.one", "2606:4700:4700::1111"} {
		if !diagHostRe.MatchString(h) {
			t.Errorf("%q rejected", h)
		}
	}
	for _, h := range []string{"-c 99 x", "a;reboot", "$(id)", "a b", ""} {
		if diagHostRe.MatchString(h) {
			t.Errorf("%q accepted", h)
		}
	}
}

// cb0401 v1 (issue #1): QENG reports NR with PCI 0 and band 0 for a live n1
// cell. The real PCI is in the NR measurement report; the serving-cell lock
// must take it from there, not expose a bogus PCI 0.
func TestParseCellLockV1PCIFromMeasReport(t *testing.T) {
	raw := `+QENG: "LTE","FDD",226,01,307758,459,2850,7,5,5,BDC,-111,-11,-77,10,0,-,-
+QENG: "NR5G-NSA",226,01,0,-94,21,-11,423130,0,3,0
+QNWCFG: "nr5g_meas_info",1,423130,459,-94,-11
`
	s := parseCellLock(raw)["serving_nr"]
	if s != (nrCell{PCI: 459, Arfcn: 423130, SCS: 15, Band: 1}) {
		t.Errorf("serving_nr = %v, want PCI 459 n1", s)
	}
}
