package main

// Raw CFR records as the router's stock /usr/sbin/cfr_test_app writes them
// to /tmp/cfr_dump_wifi{0,1}_*.bin (armed by router/cfr_capture_daemon.sh).
// Everything here was reverse-engineered on the CB0401's own hardware; see
// router/cfr-trigger for how capture is switched on.

import (
	"encoding/binary"
	"fmt"
	"math"
	"net"
)

var magicHeader = [4]byte{0xaf, 0xbe, 0xad, 0xde} // 0xDEADBEAF on disk

const (
	offTimestamp      = 0x1e // u64 LE capture time in microseconds (router clock)
	offMAC            = 0x2c // peer MAC address (6 bytes)
	fixedHdrLen       = 0x32
	successPayloadOff = 0xc0 // I/Q pairs start here in a successful record
	chainRSSIOff      = 0x40 // 4 x int32 LE per-chain RSSI (chain 0 reads 0 on this router)
)

type rawRecord struct {
	mac     string
	ts      uint64 // capture time, microseconds on the router's clock
	wide    bool   // captured wider than 20 MHz
	rcc     bool   // passive RCC capture (any frame to the AP), not a periodic per-peer one
	rssi    int8   // strongest chain's RSSI in dBm, 0 if unknown
	payload []byte // I/Q region, from successPayloadOff to the end
}

func indexOf(haystack, needle []byte) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		match := true
		for j := range needle {
			if haystack[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

func isAllZero(b []byte) bool {
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}

// splitRecords cuts one dump file into records and drops the empty ones
// (a failed capture - e.g. the peer was in power save - leaves a header
// with an all-zero body).
func splitRecords(buf []byte) []rawRecord {
	var starts []int
	for i := 0; ; {
		idx := indexOf(buf[i:], magicHeader[:])
		if idx < 0 {
			break
		}
		starts = append(starts, i+idx)
		i += idx + 4
	}
	var records []rawRecord
	for n, start := range starts {
		end := len(buf)
		if n+1 < len(starts) {
			end = starts[n+1]
		}
		body := buf[start:end]
		if len(body) <= successPayloadOff || isAllZero(body[fixedHdrLen:]) {
			continue
		}
		var rssi int8
		if len(body) >= chainRSSIOff+16 {
			for c := 0; c < 4; c++ {
				v := int32(binary.LittleEndian.Uint32(body[chainRSSIOff+c*4:]))
				if v < 0 && v >= -128 && (rssi == 0 || int8(v) > rssi) {
					rssi = int8(v)
				}
			}
		}
		records = append(records, rawRecord{
			ts:      binary.LittleEndian.Uint64(body[offTimestamp:]),
			wide:    body[offBandwidth] != 0,
			rcc:     body[offCaptureKind] == 6,
			mac:     net.HardwareAddr(body[offMAC : offMAC+6]).String(),
			rssi:    rssi,
			payload: body[successPayloadOff:],
		})
	}
	return records
}

// Where the channel actually is inside a record, measured on live captures
// (tones sit at several hundred counts; everything else is noise around
// 5-40):
//
//   - 5 GHz radio: 8388-byte records = 2049 int16 I/Q pairs, one leading
//     pair, then 4 blocks of 512 - one per receive chain. Only the first
//     256 entries of a block carry the channel (a 256-point grid at
//     312.5 kHz = 80 MHz). Captured at 20 MHz (byte 0x1a = 0) that is one
//     52-tone subchannel around entry 159; captured at 80 MHz (byte 0x1a =
//     1, `wlanconfig ... cfr start <mac> 2 ...`) the client's ACK comes as
//     a non-HT duplicate on all four 20 MHz subchannels: 4 x 52 = 208 tones
//     around entries 31, 95, 159 and 223 - four times the bandwidth, in a
//     record of the same size.
//   - 2.4 GHz radio: 1060-byte records = 217 pairs, one leading pair, then
//     2 blocks of 108; 52 tones around entry 79.
//
// Other record sizes haven't been seen often enough to map and are skipped.
const (
	offBandwidth   = 0x1a // 0 = captured at 20 MHz, 1 = wider (80 MHz duplicate)
	offCaptureKind = 0x1b // 0/1 = periodic per-peer capture, 6 = RCC (passive, any received frame)
)

type cfrLayout struct {
	pairs, chains, block, first int
	centres                     []int // 52 tones around each: centre-26..centre+26 without the centre
}

var cfrLayouts = []cfrLayout{
	{pairs: 2049, chains: 4, block: 512, first: 1, centres: []int{159}},
	{pairs: 217, chains: 2, block: 108, first: 1, centres: []int{79}},
}

var wide5 = cfrLayout{pairs: 2049, chains: 4, block: 512, first: 1, centres: []int{31, 95, 159, 223}}

// tonePositions: each extracted tone's position on the 312.5 kHz grid, for
// fitting phase slopes across the gaps between subchannels.
func (l cfrLayout) tonePositions() []float64 {
	var p []float64
	for _, c := range l.centres {
		for k := -26; k <= 26; k++ {
			if k != 0 {
				p = append(p, float64(c+k))
			}
		}
	}
	return p
}

func layoutOf(rec rawRecord) (cfrLayout, string, bool) {
	n := len(rec.payload) / 4
	for _, l := range cfrLayouts {
		if n != l.pairs {
			continue
		}
		if l.chains == 4 && rec.rcc {
			return rccLayout(rec.payload)
		}
		if l.chains == 4 && rec.wide {
			return wide5, "", true
		}
		return l, "", true
	}
	return cfrLayout{}, "", false
}

// rccCentres: the 160 MHz capture grid holds eight 20 MHz subchannels. A
// passively captured frame occupies whichever of them it was sent on (a
// 20 MHz ACK one, an 80 MHz duplicate four, ...), so which entries carry
// channel varies per frame and is detected from the record itself.
var rccCentres = []int{31, 95, 159, 223, 287, 351, 415, 479}

// rccLayout finds the occupied subchannels of one RCC record from chain
// 0's amplitudes: the guard entries between subchannels give the noise
// floor, and a subchannel counts as occupied when its mean amplitude is
// well above it. The shape string keys records of the same occupancy
// together (each shape is its own stream with a consistent tone set).
func rccLayout(payload []byte) (cfrLayout, string, bool) {
	amp := func(i int) float64 {
		k := (1 + i) * 4 // chain 0 block starts after the leading pair
		re := float64(int16(binary.LittleEndian.Uint16(payload[k:])))
		im := float64(int16(binary.LittleEndian.Uint16(payload[k+2:])))
		return math.Hypot(re, im)
	}
	var noise float64
	var nn int
	for _, c := range rccCentres {
		for i := c + 29; i < c+35; i++ { // guard entries past each subchannel's edge
			if i < 512 {
				noise += amp(i)
				nn++
			}
		}
	}
	noise /= float64(nn)
	var centres []int
	shape := 0
	for bit, c := range rccCentres {
		var m float64
		for k := -26; k <= 26; k++ {
			if k != 0 {
				m += amp(c + k)
			}
		}
		m /= 52
		if m > 4*noise+40 {
			centres = append(centres, c)
			shape |= 1 << bit
		}
	}
	if len(centres) == 0 {
		return cfrLayout{}, "", false
	}
	l := cfrLayout{pairs: 2049, chains: 4, block: 512, first: 1, centres: centres}
	return l, fmt.Sprintf("#%02x", shape), true
}

// toneCSI returns the complex channel of one record, chain by chain
// (chains x tones values), and its layout; ok false for an unmapped record
// size. Each record carries its own random phase and timing offset, common
// to all chains - see csi.go for how that is removed.
func toneCSI(rec rawRecord) ([]complex128, cfrLayout, string, bool) {
	l, shape, ok := layoutOf(rec)
	if !ok {
		return nil, l, "", false
	}
	out := make([]complex128, 0, l.chains*52*len(l.centres))
	for c := 0; c < l.chains; c++ {
		base := l.first + c*l.block
		for _, centre := range l.centres {
			for k := -26; k <= 26; k++ {
				if k == 0 {
					continue
				}
				i := (base + centre + k) * 4
				re := float64(int16(binary.LittleEndian.Uint16(rec.payload[i:])))
				im := float64(int16(binary.LittleEndian.Uint16(rec.payload[i+2:])))
				out = append(out, complex(re, im))
			}
		}
	}
	return out, l, shape, true
}
