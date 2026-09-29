#!/bin/sh
#
# Restores the 5 GHz configuration CPE Box relies on for 160 MHz across reboots:
#
# 1) The stock firmware ships with every DFS channel (52-140) in the
#    channel_block_list, which makes 160 MHz on the 5 GHz radio impossible
#    at all - a 160 MHz block from ch 36 always spans the DFS range 52-64.
#    We keep only channel 165 blocked (not usable in EU anyway) and let the
#    driver use 52-140 like every other consumer AP does.
#
# 2) htmode is forced to HT160 for wifi1, so a wifi reload after firmware
#    housekeeping doesn't drop back to HT80.
#
# 3) preCACEn=1 is set on the wifi1 radio - a runtime-only flag, gone after
#    every reboot. With pre-CAC on, the radio keeps DFS backup channels
#    already CAC-cleared in the background, so a radar hit on the current
#    channel switches to a ready spare within a beacon interval instead of
#    the mandatory 60-second CAC on the new channel.
#
# Radar detection itself is baked into Qualcomm firmware and is a
# regulatory requirement in the EU - none of this disables it, only makes
# the fallout cheap. If the driver ever moves off ch 36 because of a real
# radar hit, it'll come back on its own once the NOL timer for that
# channel expires.
#
# Called once per boot by boot.sh.
set -e

# UCI values survive reboots on their own, but the stock UI's own actions
# can rewrite them, so we assert them here every boot.
uci -q batch <<'UCI'
set wireless.@wifi-iface[1].channel_block_list='165'
set wireless.bh_ap.channel_block_list='165'
set wireless.wifi1.htmode='HT160'
commit wireless
UCI

# Runtime-only. The wifi1 radio has to already be up; if it isn't yet we
# swallow the error - boot.sh runs every minute, next tick catches it.
iwpriv wifi1 preCACEn 1 2>/dev/null || true
