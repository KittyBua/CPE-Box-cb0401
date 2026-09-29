package main

// The router-side sms-reader is baked into every cpe-box host binary and
// dumped to disk at setup time, so the release page carries one file per
// OS instead of one plus a mystery sms-reader-linux-armv7 blob users would
// otherwise wonder about.
//
// The placeholder committed at embedded/sms-reader-linux-armv7 (empty by
// default so `go build` works from a fresh clone without cross-building
// anything first) is replaced with the real ARMv7 binary by gui/build.sh
// before it kicks off the host builds. isEmbeddedSmsReaderReal tells
// callers to fall back to a fresh cross-build (setup.sh) when the running
// binary was built without a real payload.

import (
	_ "embed"
	"os"
)

//go:embed embedded/sms-reader-linux-armv7
var embeddedSmsReader []byte

// dumpEmbeddedSmsReader writes the baked-in ARMv7 sms-reader to `path`
// (0755). Returns false if the running cpe-box binary was built without
// the real payload - the caller then falls back to a fresh cross-build or
// download.
func dumpEmbeddedSmsReader(path string) (bool, error) {
	if !isEmbeddedSmsReaderReal() {
		return false, nil
	}
	if err := os.WriteFile(path, embeddedSmsReader, 0o755); err != nil {
		return false, err
	}
	return true, nil
}

func isEmbeddedSmsReaderReal() bool {
	// The checked-in placeholder is empty; a real ARMv7 sms-reader built
	// with CGO_ENABLED=0 -trimpath -ldflags="-s -w" is comfortably above
	// 100 KiB, so any non-trivial size means gui/build.sh populated it.
	return len(embeddedSmsReader) > 4096
}
