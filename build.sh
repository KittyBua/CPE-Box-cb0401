#!/bin/bash
#
# build.sh - builds every CPE Box release binary. GitHub Actions runs this
# for each release (.github/workflows/release.yml); it works the same
# locally with Go installed.
#
#   ./build.sh [OUT_DIR] [VERSION]
#
# Everything is CGO-free, so one machine cross-compiles for all targets.
# The router-side sms-reader is cross-built first and embedded into every
# host binary via //go:embed - so the release page shows one file per OS
# and setup.sh dumps the ARMv7 sms-reader out of cpe-box at install time.
#
set -e
cd "$(dirname "$0")"

OUT_DIR="$(mkdir -p "${1:-./dist}" && cd "${1:-./dist}" && pwd)"
VERSION="${2:-$(git describe --tags --always 2>/dev/null || echo dev)}"
VERSION="${VERSION#v}"
LDFLAGS="-s -w -X main.appVersion=$VERSION"

# Cross-build the router-side sms-reader first and drop it where panel/main.go's
# //go:embed picks it up. The placeholder committed in git is empty; every
# host build below embeds this real binary. We restore the placeholder at
# the end so a "git status" after a build stays clean.
EMBED="$PWD/panel/embedded/sms-reader-linux-armv7"
echo "==> sms-reader-linux-armv7 (runs on the router, embedded into every host build)"
rm -f "$EMBED"
(cd router/sms-reader && CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o "$EMBED" .)
trap 'printf "" > "$EMBED"; echo "(restored empty embed placeholder)"' EXIT

# build GOOS GOARCH OUTNAME [GOARM]
build() {
  echo "==> $3 ($1/$2${4:+ GOARM=$4})"
  (cd panel && env CGO_ENABLED=0 GOOS="$1" GOARCH="$2" ${4:+GOARM=$4} go build -trimpath -ldflags="$LDFLAGS" -o "$OUT_DIR/$3" .)
}

build darwin arm64 cpe-box-macos-arm64
build darwin amd64 cpe-box-macos-intel
build linux amd64 cpe-box-linux-amd64
build linux arm64 cpe-box-linux-arm64
build linux arm cpe-box-linux-armv7 7
build windows amd64 cpe-box-windows-amd64.exe

(cd "$OUT_DIR" && { shasum -a 256 cpe-box-* 2>/dev/null || sha256sum cpe-box-*; } > SHA256SUMS)
echo
echo "Done - version $VERSION, binaries in $OUT_DIR/"
