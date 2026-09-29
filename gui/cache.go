package main

import (
	"strings"
	"sync"
	"time"
)

// Read endpoints go through a short shared cache, so the router is polled
// the same amount whether one browser or five have the panel open, and
// concurrent requests for the same thing wait for one fetch instead of each
// opening their own SSH/AT round-trip. Errors aren't cached.
type cacheEntry struct {
	at  time.Time
	val any
}

var (
	cacheMu    sync.Mutex
	cacheData  = map[string]cacheEntry{}
	cacheLocks = map[string]*sync.Mutex{}
)

func cached(key string, ttl time.Duration, fn func() (any, error)) (any, error) {
	cacheMu.Lock()
	l := cacheLocks[key]
	if l == nil {
		l = &sync.Mutex{}
		cacheLocks[key] = l
	}
	cacheMu.Unlock()

	l.Lock()
	defer l.Unlock()
	cacheMu.Lock()
	e, found := cacheData[key]
	cacheMu.Unlock()
	if found && time.Since(e.at) < ttl {
		return e.val, nil
	}
	v, err := fn()
	if err != nil {
		return nil, err
	}
	cacheMu.Lock()
	cacheData[key] = cacheEntry{time.Now(), v}
	cacheMu.Unlock()
	return v, nil
}

// invalidate drops the given keys, and any "key?params" variants of them.
func invalidate(keys ...string) {
	cacheMu.Lock()
	for _, k := range keys {
		delete(cacheData, k)
		for ck := range cacheData {
			if strings.HasPrefix(ck, k+"?") {
				delete(cacheData, ck)
			}
		}
	}
	cacheMu.Unlock()
}
