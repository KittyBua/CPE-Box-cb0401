package main

// Moving bodies on the plan: a particle filter over positions and
// velocities, driven by what every anchor link measures.
//
// Every link is router -> reflection off a person -> anchor, and a link
// only feels movement near its router-anchor line (sensitivity falls with
// the extra path length the reflection takes). Each link's moving power,
// divided by that link's own typical strong response, says which links the
// person is close to; particles move with a random-walk velocity and never
// cross a drawn wall. (A Doppler velocity term - Widar's path-rate model -
// was tried and removed: on a recorded walk along a known route it made
// no difference, with these anchors and without known antenna geometry.)
//
// Measured honestly on that walk: 2.6 m median error in a 9.4 x 4.5 m flat,
// no better than always pointing at its middle (2.2 m). Four anchors, three
// of them on one side of the router, don't pin a person down; more anchors
// spread around the rooms are what would.
//
// Several bodies: some particles are re-seeded everywhere on each step, so
// a second person elsewhere gets its own cluster; the cloud's clusters are
// reported as separate bodies. Two people in the same part of the flat look
// like one to four links from one router - that isn't separable.

import (
	"math"
	"math/rand"
	"sort"
	"strconv"
	"time"
)

const (
	nParticles   = 1500
	reseedShare  = 0.08
	maxSpeed     = 2.0  // m/s, walking
	accelNoise   = 2.0  // m/s^2, how freely direction/speed change
	sensScale    = 2.5  // m of extra path length at which a link's sensitivity falls to 1/e
	powerSigma   = 0.12 // spread of the observed vs predicted share of moving power
	bodyMinShare = 0.25 // a cluster needs this share of the weight to count as a body
	cleanThr     = 6.0  // dB: links with a threshold up to this are quiet enough to raise an alarm
	presenceOn   = 1000 * time.Millisecond
	presenceOff  = 5 * time.Second
	glideTime    = 1.2 // s, how slowly a shown ball follows the estimate
	secondAfter  = 3 * time.Second
	maxShown     = 2
	bodyCell     = 0.4 // m, clustering grid
	forgetAfter  = 20 * time.Second
)

type particle struct{ x, y, vx, vy, w float64 }

// Body is one moving thing on the plan.
type Body struct {
	ID     int     `json:"id"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Share  float64 `json:"share"`  // of the particle weight: how sure
	Spread float64 `json:"spread"` // m, how scattered its particles are
	Speed  float64 `json:"speed"`  // m/s
}

// TrackState is what the page gets about tracking.
type TrackState struct {
	Bodies []Body     `json:"bodies"`
	Ready  bool       `json:"ready"`  // router and at least two anchors placed
	Reason string     `json:"reason"` // why not ready
	Moving float64    `json:"moving"` // 0..1 overall movement
	Bounds [4]float64 `json:"bounds,omitempty"`
}

type linkObs struct {
	mac    string
	a      [2]float64 // anchor position
	moving float64    // linear moving power above normal (0 = normal)
	active bool
}

type tracker struct {
	rng      *rand.Rand
	ps       []particle
	lastT    time.Time
	lastMove time.Time
	trigFrom time.Time // start of the current stretch of triggers
	trigLast time.Time
	present  bool
	shown    []*shownBody
	nextID   int
	sig      string // plan signature: reset when the plan changes
	inside   *insideMask
	resp     map[string][]float64 // per link: its moving power at moments with movement
}

// Links differ a lot in how strongly they respond at all (the vacuum's
// 2.4 GHz link in the router's room reacts to everything, the lamp's
// through-wall link hardly): each link's moving power is divided by its
// own typical strong response (90th percentile of the last ~hour of
// moments with movement), so "every link rose by its usual amount" reads
// as near the router, not as "the loudest link wins".
const respKeep = 15000

func (t *tracker) learnResponse(mac string, v float64) {
	if t.resp == nil {
		t.resp = map[string][]float64{}
	}
	h := append(t.resp[mac], v)
	if len(h) > respKeep {
		h = h[len(h)-respKeep:]
	}
	t.resp[mac] = h
}

func (t *tracker) gain(mac string) float64 {
	h := t.resp[mac]
	if len(h) < 40 {
		return 1
	}
	return math.Max(1, percentile(h, 0.9))
}

// insideMask: which parts of the plan are indoors - everything that can't
// be reached from outside the drawn walls without crossing one. Hypotheses
// live only there (people outside the window move the links too, but they
// are not in the flat).
type insideMask struct {
	x0, y0, cell float64
	nx, ny       int
	in           []bool
	cells        []int // indexes of inside cells, for spawning
}

func buildInside(pl Plan) *insideMask {
	if len(pl.Walls) < 3 {
		return nil
	}
	b := [4]float64{math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)}
	for _, w := range pl.Walls {
		b[0], b[1] = math.Min(b[0], math.Min(w[0], w[2])), math.Min(b[1], math.Min(w[1], w[3]))
		b[2], b[3] = math.Max(b[2], math.Max(w[0], w[2])), math.Max(b[3], math.Max(w[1], w[3]))
	}
	m := &insideMask{x0: b[0] - 0.5, y0: b[1] - 0.5, cell: 0.1}
	m.nx = int((b[2]-b[0]+1)/m.cell) + 1
	m.ny = int((b[3]-b[1]+1)/m.cell) + 1
	outside := make([]bool, m.nx*m.ny)
	center := func(i, j int) (float64, float64) {
		return m.x0 + (float64(i)+0.5)*m.cell, m.y0 + (float64(j)+0.5)*m.cell
	}
	var queue []int
	for i := 0; i < m.nx; i++ {
		for _, j := range []int{0, m.ny - 1} {
			if !outside[j*m.nx+i] {
				outside[j*m.nx+i] = true
				queue = append(queue, j*m.nx+i)
			}
		}
	}
	for j := 0; j < m.ny; j++ {
		for _, i := range []int{0, m.nx - 1} {
			if !outside[j*m.nx+i] {
				outside[j*m.nx+i] = true
				queue = append(queue, j*m.nx+i)
			}
		}
	}
	for len(queue) > 0 {
		c := queue[0]
		queue = queue[1:]
		i, j := c%m.nx, c/m.nx
		ax, ay := center(i, j)
		for _, d := range [][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
			ii, jj := i+d[0], j+d[1]
			if ii < 0 || ii >= m.nx || jj < 0 || jj >= m.ny || outside[jj*m.nx+ii] {
				continue
			}
			bx, by := center(ii, jj)
			blocked := false
			for _, w := range pl.Walls {
				if segCross(ax, ay, bx, by, w[0], w[1], w[2], w[3]) {
					blocked = true
					break
				}
			}
			if !blocked {
				outside[jj*m.nx+ii] = true
				queue = append(queue, jj*m.nx+ii)
			}
		}
	}
	m.in = make([]bool, len(outside))
	for k, o := range outside {
		if !o {
			m.in[k] = true
			m.cells = append(m.cells, k)
		}
	}
	if len(m.cells) < 20 {
		return nil // walls don't enclose anything (not closed): no mask
	}
	return m
}

func (m *insideMask) at(x, y float64) bool {
	i, j := int((x-m.x0)/m.cell), int((y-m.y0)/m.cell)
	return i >= 0 && i < m.nx && j >= 0 && j < m.ny && m.in[j*m.nx+i]
}

func newTracker() *tracker { return &tracker{rng: rand.New(rand.NewSource(1))} }

func planBoundsOf(pl Plan, pts [][2]float64) [4]float64 {
	b := [4]float64{math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)}
	add := func(x, y float64) {
		b[0], b[1] = math.Min(b[0], x), math.Min(b[1], y)
		b[2], b[3] = math.Max(b[2], x), math.Max(b[3], y)
	}
	for _, w := range pl.Walls {
		add(w[0], w[1])
		add(w[2], w[3])
	}
	if len(pl.Walls) < 3 {
		// no rooms drawn: the area around the router and anchors
		for _, p := range pts {
			add(p[0]-2, p[1]-2)
			add(p[0]+2, p[1]+2)
		}
		return b
	}
	return [4]float64{b[0] + 0.1, b[1] + 0.1, b[2] - 0.1, b[3] - 0.1}
}

func segCross(ax, ay, bx, by, cx, cy, dx, dy float64) bool {
	d := (bx-ax)*(dy-cy) - (by-ay)*(dx-cx)
	if d == 0 {
		return false
	}
	t := ((cx-ax)*(dy-cy) - (cy-ay)*(dx-cx)) / d
	u := ((cx-ax)*(by-ay) - (cy-ay)*(bx-ax)) / d
	return t >= 0 && t <= 1 && u >= 0 && u <= 1
}

func (t *tracker) spawn(b [4]float64) particle {
	a := t.rng.Float64() * 2 * math.Pi
	s := t.rng.Float64() * 1.0
	p := particle{
		x: b[0] + t.rng.Float64()*(b[2]-b[0]), y: b[1] + t.rng.Float64()*(b[3]-b[1]),
		vx: s * math.Cos(a), vy: s * math.Sin(a), w: 1,
	}
	if m := t.inside; m != nil {
		c := m.cells[t.rng.Intn(len(m.cells))]
		p.x = m.x0 + (float64(c%m.nx)+t.rng.Float64())*m.cell
		p.y = m.y0 + (float64(c/m.nx)+t.rng.Float64())*m.cell
	}
	return p
}

// step advances the filter with one tick of link states.
func (t *tracker) step(now time.Time, pl Plan, links []LinkState) TrackState {
	st := TrackState{Bodies: []Body{}}
	if pl.Router == nil {
		st.Reason = "Place the router on the plan (Edit plan) to see moving bodies."
		t.ps = nil
		return st
	}
	R := *pl.Router
	var obs []linkObs
	pts := [][2]float64{R}
	var total float64
	for _, l := range links {
		p, ok := pl.Devices[l.MAC]
		if !ok || l.Stale || l.Learning {
			continue
		}
		pts = append(pts, p)
		o := linkObs{a: p, mac: l.MAC}
		o.moving = math.Max(0, math.Pow(10, l.Score/10)-1)
		total += o.moving
		o.active = l.Score > l.Threshold*0.5
		obs = append(obs, o)
	}
	if len(obs) < 2 {
		st.Reason = "Place at least two anchors (the devices being captured) on the plan to see moving bodies."
		t.ps = nil
		return st
	}
	st.Ready = true
	b := planBoundsOf(pl, pts)
	st.Bounds = b

	sig := planSig(pl)
	if sig != t.sig || len(t.ps) != nParticles {
		t.sig = sig
		t.inside = buildInside(pl)
		t.ps = make([]particle, nParticles)
		for i := range t.ps {
			t.ps[i] = t.spawn(b)
		}
	}
	dt := tickEvery.Seconds()
	if !t.lastT.IsZero() {
		dt = math.Max(0.05, math.Min(1, now.Sub(t.lastT).Seconds()))
	}
	t.lastT = now

	moving := t.presence(now, links)
	if moving {
		t.lastMove = now
		for _, o := range obs {
			t.learnResponse(o.mac, o.moving)
		}
	}
	total = 0
	for k := range obs {
		obs[k].moving /= t.gain(obs[k].mac)
		total += obs[k].moving
	}
	st.Moving = math.Min(1, total/10)
	if !moving {
		// a pause: keep the hypotheses where they are (slowing down) and
		// hold the shown balls for a moment; after a long quiet spell forget
		// the hypotheses - the next movement may start anywhere
		for i := range t.ps {
			t.ps[i].vx *= 0.8
			t.ps[i].vy *= 0.8
		}
		if now.Sub(t.lastMove) > forgetAfter {
			for i := range t.ps {
				t.ps[i] = t.spawn(b)
			}
		}
		st.Bodies = t.display(now, dt, nil)
		return st
	}
	// predict: constant velocity with random acceleration; walls block
	sa := accelNoise * math.Sqrt(dt)
	for i := range t.ps {
		p := &t.ps[i]
		p.vx += t.rng.NormFloat64() * sa
		p.vy += t.rng.NormFloat64() * sa
		if s := math.Hypot(p.vx, p.vy); s > maxSpeed {
			p.vx, p.vy = p.vx*maxSpeed/s, p.vy*maxSpeed/s
		}
		nx, ny := p.x+p.vx*dt, p.y+p.vy*dt
		blocked := nx < b[0] || nx > b[2] || ny < b[1] || ny > b[3] || (t.inside != nil && !t.inside.at(nx, ny))
		for _, w := range pl.Walls {
			if blocked {
				break
			}
			blocked = segCross(p.x, p.y, nx, ny, w[0], w[1], w[2], w[3])
		}
		if blocked {
			p.vx, p.vy = -0.3*p.vx, -0.3*p.vy
		} else {
			p.x, p.y = nx, ny
		}
	}
	// a few fresh hypotheses everywhere, so a new or second body is found
	for k := 0; k < int(reseedShare*nParticles); k++ {
		t.ps[t.rng.Intn(nParticles)] = t.spawn(b)
	}

	// weight
	var wsum float64
	for i := range t.ps {
		p := &t.ps[i]
		lw := 0.0
		var fs, ms float64
		f := make([]float64, len(obs))
		for k, o := range obs {
			dR := math.Hypot(p.x-R[0], p.y-R[1])
			dA := math.Hypot(p.x-o.a[0], p.y-o.a[1])
			direct := math.Hypot(o.a[0]-R[0], o.a[1]-R[1])
			f[k] = sensitivity(dR, dA, direct)
			fs += f[k]
			ms += o.moving
		}
		if ms > 0 && fs > 0 {
			// which links feel it, relative to each other...
			for k, o := range obs {
				d := o.moving/ms - f[k]/fs
				lw -= d * d / (2 * powerSigma * powerSigma)
			}
			// ...and somebody far from every link can't move any of them
			mf := 0.0
			for _, v := range f {
				mf = math.Max(mf, v)
			}
			lw += math.Min(1, ms/3) * math.Log(mf+0.02)
		}
		p.w = math.Exp(lw)
		wsum += p.w
	}
	if wsum <= 0 || math.IsNaN(wsum) {
		for i := range t.ps {
			t.ps[i] = t.spawn(b)
		}
		return st
	}
	for i := range t.ps {
		t.ps[i].w /= wsum
	}
	st.Bodies = t.display(now, dt, t.cluster(b))
	t.resample()
	return st
}

func planSig(pl Plan) string {
	s := ""
	if pl.Router != nil {
		s += ftoa(pl.Router[0]) + "," + ftoa(pl.Router[1])
	}
	keys := make([]string, 0, len(pl.Devices))
	for k := range pl.Devices {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		s += ";" + k + ftoa(pl.Devices[k][0]) + ftoa(pl.Devices[k][1])
	}
	for _, w := range pl.Walls {
		s += "|" + ftoa(w[0]) + ftoa(w[1]) + ftoa(w[2]) + ftoa(w[3])
	}
	return s
}

func ftoa(f float64) string { return strconv.FormatFloat(f, 'f', 2, 64) }

// resample: systematic, keeps the cloud from collapsing onto few particles.
func (t *tracker) resample() {
	n := len(t.ps)
	out := make([]particle, n)
	u := t.rng.Float64() / float64(n)
	c := t.ps[0].w
	i := 0
	for j := 0; j < n; j++ {
		for u > c && i < n-1 {
			i++
			c += t.ps[i].w
		}
		out[j] = t.ps[i]
		out[j].w = 1 / float64(n)
		u += 1 / float64(n)
	}
	t.ps = out
}

// cluster finds the weight's peaks on a coarse grid (smoothed), and turns
// each big enough one into a body, keeping IDs of bodies close to last time's.
func (t *tracker) cluster(b [4]float64) []Body {
	nx := int((b[2]-b[0])/bodyCell) + 1
	ny := int((b[3]-b[1])/bodyCell) + 1
	g := make([]float64, nx*ny)
	for _, p := range t.ps {
		i := int((p.x - b[0]) / bodyCell)
		j := int((p.y - b[1]) / bodyCell)
		if i >= 0 && i < nx && j >= 0 && j < ny {
			g[j*nx+i] += p.w
		}
	}
	s := make([]float64, nx*ny)
	for j := 0; j < ny; j++ {
		for i := 0; i < nx; i++ {
			var v float64
			for dj := -2; dj <= 2; dj++ {
				for di := -2; di <= 2; di++ {
					ii, jj := i+di, j+dj
					if ii >= 0 && ii < nx && jj >= 0 && jj < ny {
						v += g[jj*nx+ii] * math.Exp(-float64(di*di+dj*dj)/2)
					}
				}
			}
			s[j*nx+i] = v
		}
	}
	type peak struct {
		x, y float64
		v    float64
	}
	var peaks []peak
	for j := 0; j < ny; j++ {
		for i := 0; i < nx; i++ {
			v := s[j*nx+i]
			if v <= 0 {
				continue
			}
			isMax := true
			for dj := -3; dj <= 3 && isMax; dj++ {
				for di := -3; di <= 3; di++ {
					ii, jj := i+di, j+dj
					if (di != 0 || dj != 0) && ii >= 0 && ii < nx && jj >= 0 && jj < ny && s[jj*nx+ii] > v {
						isMax = false
						break
					}
				}
			}
			if isMax {
				peaks = append(peaks, peak{b[0] + (float64(i)+0.5)*bodyCell, b[1] + (float64(j)+0.5)*bodyCell, v})
			}
		}
	}
	sort.Slice(peaks, func(i, j int) bool { return peaks[i].v > peaks[j].v })
	var bodies []Body
	for _, pk := range peaks {
		if len(bodies) >= 3 {
			break
		}
		// refine: particles within 1.2 m of the peak
		var w, x, y, vx, vy float64
		for _, p := range t.ps {
			if math.Hypot(p.x-pk.x, p.y-pk.y) < 1.2 {
				w += p.w
				x += p.w * p.x
				y += p.w * p.y
				vx += p.w * p.vx
				vy += p.w * p.vy
			}
		}
		if w < bodyMinShare {
			continue
		}
		x, y = x/w, y/w
		var sp float64
		for _, p := range t.ps {
			if d := math.Hypot(p.x-pk.x, p.y-pk.y); d < 1.2 {
				sp += p.w * math.Hypot(p.x-x, p.y-y)
			}
		}
		dup := false
		for _, o := range bodies {
			if math.Hypot(o.X-x, o.Y-y) < 1.2 {
				dup = true
			}
		}
		if dup {
			continue
		}
		bodies = append(bodies, Body{X: round2(x), Y: round2(y), Share: round2(w), Spread: round2(sp / w), Speed: round2(math.Hypot(vx, vy) / w)})
	}
	return bodies
}

type shownBody struct {
	Body
	since, seen time.Time
	confirmed   bool
}

// presence: movement counts only when a clean link (a low noise threshold -
// here the vacuum's) sees it; links that are noisy by nature only help
// place the ball. It must go on for presenceOn (short gaps allowed) to
// switch presence on, and stays on until presenceOff without any trigger.
// Returns whether this tick carries movement to track.
func (t *tracker) presence(now time.Time, links []LinkState) bool {
	trig, anyClean := false, false
	for _, l := range links {
		if l.Stale || l.Learning {
			continue
		}
		if l.Threshold <= cleanThr {
			anyClean = true
			if l.Motion {
				trig = true
			}
		}
	}
	if !anyClean { // no clean link at all: demand a clear excess on any link
		for _, l := range links {
			if !l.Stale && !l.Learning && l.Score > 1.5*l.Threshold {
				trig = true
			}
		}
	}
	if trig {
		if t.trigFrom.IsZero() || now.Sub(t.trigLast) > time.Second {
			t.trigFrom = now
		}
		t.trigLast = now
		if now.Sub(t.trigFrom) >= presenceOn {
			t.present = true
		}
	} else if now.Sub(t.trigLast) > presenceOff {
		t.present = false
		t.trigFrom = time.Time{}
	}
	return trig
}

// display: what the page shows. Balls glide towards the estimate (they
// don't jump), the strongest estimate is shown as soon as presence is on,
// a second one only once it has persisted for secondAfter, and a ball
// without support for secondAfter is dropped.
func (t *tracker) display(now time.Time, dt float64, est []Body) []Body {
	if !t.present {
		t.shown = nil
		return []Body{}
	}
	used := make([]bool, len(t.shown))
	for _, e := range est {
		best, bd := -1, 2.5
		for i, s := range t.shown {
			if d := math.Hypot(s.X-e.X, s.Y-e.Y); d < bd && !used[i] {
				best, bd = i, d
			}
		}
		if best >= 0 {
			s := t.shown[best]
			used[best] = true
			k := math.Min(1, dt/glideTime)
			s.X += (e.X - s.X) * k
			s.Y += (e.Y - s.Y) * k
			s.Share, s.Spread, s.Speed = e.Share, e.Spread, e.Speed
			s.seen = now
			if !s.confirmed && now.Sub(s.since) >= secondAfter {
				s.confirmed = true
			}
			continue
		}
		t.nextID++
		nb := &shownBody{Body: e, since: now, seen: now}
		nb.ID = t.nextID
		t.shown = append(t.shown, nb)
		used = append(used, true)
	}
	confirmed := 0
	for _, s := range t.shown {
		if s.confirmed {
			confirmed++
		}
	}
	var keep []*shownBody
	var out []Body
	for _, s := range t.shown {
		if now.Sub(s.seen) > secondAfter {
			continue
		}
		if !s.confirmed && confirmed == 0 {
			s.confirmed = true // the first ball needs no extra wait: presence already did
			confirmed++
		}
		keep = append(keep, s)
		if s.confirmed && len(out) < maxShown {
			b := s.Body
			b.X, b.Y = round2(b.X), round2(b.Y)
			out = append(out, b)
		}
	}
	t.shown = keep
	if out == nil {
		out = []Body{}
	}
	return out
}

func round2(f float64) float64 { return math.Round(f*100) / 100 }

// sensitivity: how strongly a person at distances dR (router) and dA
// (anchor) moves a link of length direct, relative to its strongest case:
// falls with the extra path length the reflection takes. 2.5 m was the
// best of 0.6-2.5 m on a recorded walk along a known route (2026-09-26).
func sensitivity(dR, dA, direct float64) float64 {
	return math.Exp(-(dR + dA - direct) / sensScale)
}
