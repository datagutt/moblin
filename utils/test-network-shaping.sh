#!/usr/bin/env bash
# Network shaping helper for testing Moblin's SRT/SRTLA stack on a Mac.
# Wraps macOS's built-in pf + dummynet so you can apply a named profile
# (clean, lossy, cellular, storm, etc.) to a target UDP port without
# touching the rest of your network.
#
# Profiles target a destination UDP port (default 5000) so web/ssh/etc
# stay clean while the SRT stream gets shaped. Run a local SRT receiver
# (e.g. ffmpeg listening on udp:5000), point Moblin at it, then apply a
# profile and watch the adaptive bitrate respond.
#
# Usage:
#   ./test-network-shaping.sh setup
#   ./test-network-shaping.sh apply <profile>   [iface] [port]
#   ./test-network-shaping.sh storm             [iface] [port]
#   ./test-network-shaping.sh profiles
#   ./test-network-shaping.sh status
#   ./test-network-shaping.sh teardown
#
# Examples:
#   ./test-network-shaping.sh apply lte-bad
#   ./test-network-shaping.sh apply clean
#   ./test-network-shaping.sh storm
#   IFACE=en7 PORT=5000 ./test-network-shaping.sh apply wifi-meh
#
# Optional second-uplink fakery:
#   ./test-network-shaping.sh fake-uplinks-up    # create vlan100 / vlan200
#   ./test-network-shaping.sh fake-uplinks-down
# Caveat: vlan sub-interfaces over a single physical nic share the
# real congestion domain. They give NWPathMonitor a second "interface"
# but they're not truly independent paths. Useful for poking at the
# scheduler code, not for measuring real bonding behaviour.

set -euo pipefail

readonly PIPE_ID=1
readonly ANCHOR=moblin.shaping
DEFAULT_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || echo en0)
IFACE=${IFACE:-${2:-$DEFAULT_IFACE}}
PORT=${PORT:-${3:-5000}}

need_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "Re-running under sudo (need pf/dummynet privileges)..." >&2
        exec sudo -E IFACE="$IFACE" PORT="$PORT" "$0" "$@"
    fi
}

apply_pipe() {
    local bw=$1 delay=$2 plr=$3 queue=${4:-50}
    dnctl -q flush
    dnctl pipe $PIPE_ID config bw "$bw" delay "${delay}ms" plr "$plr" queue "${queue}"
    # Replace any prior pf rule under our anchor.
    cat <<EOF | pfctl -a "$ANCHOR" -f - 2>/dev/null
dummynet out on $IFACE proto udp from any to any port $PORT pipe $PIPE_ID
EOF
    pfctl -E 2>/dev/null || true
    echo "applied: ${bw}, ${delay}ms delay, ${plr} loss on $IFACE:$PORT (queue ${queue})"
}

profile_clean() {
    dnctl -q flush
    pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    echo "shaping cleared"
}

profile_wifi_good()    { apply_pipe 50Mbit/s 10 0      50; }
profile_wifi_meh()     { apply_pipe 10Mbit/s 40 0.01   50; }
profile_lte_good()     { apply_pipe 20Mbit/s 50 0.005  50; }
profile_lte_typical()  { apply_pipe  8Mbit/s 80 0.01   50; }
profile_lte_bad()      { apply_pipe  3Mbit/s 150 0.05  30; }
profile_lte_terrible() { apply_pipe  1Mbit/s 300 0.10  20; }
profile_3g()           { apply_pipe  1Mbit/s 250 0.03  30; }
profile_edge()         { apply_pipe 256Kbit/s 600 0.05 20; }
profile_high_jitter()  { apply_pipe 10Mbit/s 100 0.02  20; }

storm() {
    # Run a "good link -> sudden congestion -> recovery" sequence so we
    # can watch the predictive abr decreaseFast/lossHold/recovery cycle.
    echo "STORM phase 1/4: clean lte-good for 8s"
    profile_lte_good
    sleep 8
    echo "STORM phase 2/4: lte-bad for 12s (expect decreaseFast chain)"
    profile_lte_bad
    sleep 12
    echo "STORM phase 3/4: lte-typical for 10s (recovery)"
    profile_lte_typical
    sleep 10
    echo "STORM phase 4/4: clean wifi-good for 8s (full climb)"
    profile_wifi_good
    sleep 8
    profile_clean
    echo "STORM done"
}

handover() {
    # Brief total blackout (link change), then recovery on the other side.
    echo "HANDOVER: 2s blackout + 5s of lte-bad + recovery"
    apply_pipe 1Kbit/s 1000 1.0 5
    sleep 2
    profile_lte_bad
    sleep 5
    profile_lte_typical
    sleep 10
    profile_clean
    echo "HANDOVER done"
}

cellular_walk() {
    # Mimics walking through a busy area: alternating between lte-typical
    # and lte-bad with quick transitions for 60 seconds.
    echo "CELLULAR-WALK: alternating typical/bad for 60s"
    for _ in 1 2 3; do
        profile_lte_typical; sleep 8
        profile_lte_bad;     sleep 6
        profile_lte_typical; sleep 4
        profile_lte_terrible; sleep 2
    done
    profile_clean
    echo "CELLULAR-WALK done"
}

list_profiles() {
    cat <<EOF
profiles (bw / delay / loss):
  clean           no shaping
  wifi-good       50Mbit/s  10ms  0.0%
  wifi-meh        10Mbit/s  40ms  1.0%
  lte-good        20Mbit/s  50ms  0.5%
  lte-typical      8Mbit/s  80ms  1.0%
  lte-bad          3Mbit/s 150ms  5.0%
  lte-terrible     1Mbit/s 300ms 10.0%
  3g               1Mbit/s 250ms  3.0%
  edge            256Kbit/s 600ms 5.0%
  high-jitter     10Mbit/s 100ms  2.0%

scenarios (drive a sequence of profiles):
  storm           clean -> bad -> typical -> clean over ~38s
  handover        brief blackout -> bad -> typical -> clean over ~17s
  cellular-walk   alternating typical/bad/terrible for ~60s
EOF
}

status() {
    echo "=== dummynet pipes ==="
    dnctl list 2>/dev/null || echo "(none)"
    echo
    echo "=== pf anchor $ANCHOR ==="
    pfctl -a "$ANCHOR" -s rules 2>/dev/null || echo "(empty)"
    echo
    echo "=== pf status ==="
    pfctl -s info 2>/dev/null | head -3 || true
}

setup() {
    # Ensure pf is enabled. dummynet pipes are created on demand.
    pfctl -E 2>/dev/null || true
    echo "pf enabled; ready to apply profiles."
    echo "iface=$IFACE port=$PORT (override with IFACE= / PORT= env vars)"
}

teardown() {
    profile_clean
    pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    # Don't disable pf globally; the user may have other anchors.
    echo "shaping removed (pf left enabled)"
}

fake_uplinks_up() {
    # VLAN sub-interfaces over the chosen physical interface. NWPathMonitor
    # will see vlan100 / vlan200 as wiredEthernet interfaces. They share
    # $IFACE's real congestion domain, so this is only good enough for
    # exercising the scheduler/scoring code paths.
    ifconfig vlan100 create vlan 100 vlandev "$IFACE" 2>/dev/null || true
    ifconfig vlan100 inet 192.168.91.1 netmask 255.255.255.0 up
    ifconfig vlan200 create vlan 200 vlandev "$IFACE" 2>/dev/null || true
    ifconfig vlan200 inet 192.168.92.1 netmask 255.255.255.0 up
    echo "created vlan100 (192.168.91.1) and vlan200 (192.168.92.1) over $IFACE"
    echo "NB: both share $IFACE's congestion domain; this is for code-path testing only."
}

fake_uplinks_down() {
    ifconfig vlan100 destroy 2>/dev/null || true
    ifconfig vlan200 destroy 2>/dev/null || true
    echo "removed vlan100 / vlan200"
}

cmd=${1:-}
case "$cmd" in
    setup)            need_sudo "$@"; setup ;;
    teardown)         need_sudo "$@"; teardown ;;
    profiles)         list_profiles ;;
    status)           need_sudo "$@"; status ;;
    apply)
        need_sudo "$@"
        profile=${2:-}
        case "$profile" in
            clean)         profile_clean ;;
            wifi-good)     profile_wifi_good ;;
            wifi-meh)      profile_wifi_meh ;;
            lte-good)      profile_lte_good ;;
            lte-typical)   profile_lte_typical ;;
            lte-bad)       profile_lte_bad ;;
            lte-terrible)  profile_lte_terrible ;;
            3g)            profile_3g ;;
            edge)          profile_edge ;;
            high-jitter)   profile_high_jitter ;;
            *) echo "unknown profile: $profile" >&2; list_profiles; exit 1 ;;
        esac
        ;;
    storm)            need_sudo "$@"; storm ;;
    handover)         need_sudo "$@"; handover ;;
    cellular-walk)    need_sudo "$@"; cellular_walk ;;
    fake-uplinks-up)   need_sudo "$@"; fake_uplinks_up ;;
    fake-uplinks-down) need_sudo "$@"; fake_uplinks_down ;;
    ""|-h|--help|help)
        cat <<EOF
Usage:
  $0 setup
  $0 apply <profile>
  $0 storm | handover | cellular-walk
  $0 profiles
  $0 status
  $0 teardown
  $0 fake-uplinks-up | fake-uplinks-down

Environment / positional args:
  IFACE=<iface>   physical interface to shape (default: $DEFAULT_IFACE)
  PORT=<port>     destination UDP port (default: 5000)

Typical session:
  1) run an SRT listener: ffmpeg -i 'srt://0.0.0.0:5000?mode=listener&latency=2000' -f null -
  2) start Moblin streaming to 127.0.0.1:5000
  3) sudo $0 setup
  4) sudo $0 apply lte-bad
  5) sudo $0 storm
  6) sudo $0 teardown
EOF
        ;;
    *) echo "unknown command: $cmd"; exit 1 ;;
esac
