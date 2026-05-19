#!/usr/bin/env bash
# pc_c_mode.sh — switch PC c's routing between two benchmark modes.
#
# PC c sits at a junction:
#   - eno3np0 (NM Shared, 10.42.0.1/24) → iptime hub → PC e, PC f  (clean-LAN bench)
#   - wg0 (WireGuard b↔c)               → PC b      → PC a         (a↔d bench)
#   - enx9cebe8606e07 (NM Shared)       → PC d direct (10.42.2.0/24, always on)
#
# Both clean-LAN and a↔d paths use 10.42.0.0/24 — and that's exactly the
# conflict: the hub-facing connected route on eno3np0 shadows the
# `10.42.0.0/24 via 10.99.0.1 dev wg0` route used for a↔d (because
# connected scope:link wins over gateway routes for the same prefix).
#
# This script flips PC c between the two modes without touching the
# WireGuard tunnel itself (wg0 stays up).
#
# Usage:
#   bash pc_c_mode.sh abcd        # route 10.42.0.0/24 over wg0 → for a↔d bench
#   bash pc_c_mode.sh clean_lan   # route 10.42.0.0/24 over eno3np0 → for e/f bench
#   bash pc_c_mode.sh status      # show current 10.42.0.0/24 path
#
# Env vars (override defaults):
#   HUB_IFACE=eno3np0       hub-facing iface on PC c (e/f connected via switch)
#   WG_IFACE=wg0            WireGuard iface
#   WG_GATEWAY=10.99.0.1    b's WG IP

set -e

MODE="${1:-}"
HUB_IFACE="${HUB_IFACE:-eno3np0}"
WG_IFACE="${WG_IFACE:-wg0}"
WG_GATEWAY="${WG_GATEWAY:-10.99.0.1}"
TARGET_NET="10.42.0.0/24"

show_status() {
  echo "--- 10.42.0.0/24 routes ---"
  ip route show "$TARGET_NET" || echo "(no route)"
  echo "--- ip route get 10.42.0.141 (PC a) ---"
  ip route get 10.42.0.141 2>&1 || true
  echo "--- $HUB_IFACE state ---"
  ip -br a show "$HUB_IFACE" 2>&1 || echo "(iface missing)"
  echo "--- $WG_IFACE state ---"
  ip -br a show "$WG_IFACE" 2>&1 || echo "(iface missing)"
  echo "--- ip_forward ---"
  cat /proc/sys/net/ipv4/ip_forward
}

ensure_forward() {
  if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
    echo ">>> enabling ip_forward"
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null
  fi
}

case "$MODE" in
  abcd)
    echo ">>> switching PC c to a↔d mode"
    if ! ip link show "$WG_IFACE" >/dev/null 2>&1; then
      echo "ERROR: $WG_IFACE not present. Bring up the WG tunnel first" >&2
      echo "       (bash network/setup_wg.sh c)." >&2
      exit 1
    fi

    # Bring down hub-side NM connection (kills 10.42.0.1/24 on eno3np0
    # so its connected route stops shadowing the wg0 path).
    CONN_NAME=$(nmcli -t -f NAME,DEVICE c show --active 2>/dev/null \
                  | awk -F: -v d="$HUB_IFACE" '$2==d{print $1; exit}')
    if [[ -n "$CONN_NAME" ]]; then
      echo ">>> bringing down NM connection '$CONN_NAME' (hub side)"
      sudo nmcli c down "$CONN_NAME" || true
    fi

    # Belt-and-suspenders: drop any manually-added connected route on hub iface
    sudo ip route del "$TARGET_NET" dev "$HUB_IFACE" 2>/dev/null || true

    # Ensure wg0 route present
    if ! ip route show "$TARGET_NET" | grep -q "via ${WG_GATEWAY} dev ${WG_IFACE}"; then
      echo ">>> adding $TARGET_NET via $WG_GATEWAY dev $WG_IFACE"
      sudo ip route add "$TARGET_NET" via "$WG_GATEWAY" dev "$WG_IFACE"
    fi

    ensure_forward
    echo
    show_status
    echo
    echo ">>> PC c now in a↔d mode. ping PC a from PC d (via PC c forward) should work."
    ;;

  clean_lan)
    echo ">>> switching PC c to clean-LAN (e/f) mode"

    # Remove wg0 route so it doesn't compete with the hub connected route
    if ip route show "$TARGET_NET" | grep -q "via ${WG_GATEWAY} dev ${WG_IFACE}"; then
      echo ">>> removing $TARGET_NET via $WG_GATEWAY dev $WG_IFACE"
      sudo ip route del "$TARGET_NET" via "$WG_GATEWAY" dev "$WG_IFACE"
    fi

    # Bring hub NM connection back up
    CONN_NAME=$(nmcli -t -f NAME,DEVICE c show 2>/dev/null \
                  | awk -F: -v d="$HUB_IFACE" '$2==d{print $1; exit}')
    if [[ -n "$CONN_NAME" ]]; then
      echo ">>> bringing up NM connection '$CONN_NAME' (hub side)"
      sudo nmcli c up "$CONN_NAME" || true
    else
      echo "WARNING: no NM connection found for $HUB_IFACE — bring it up manually" >&2
    fi

    # NM Shared often adds the IP with `noprefixroute`, leaving the
    # auto connected route missing. Re-add it manually if so.
    if ip -br a show "$HUB_IFACE" 2>/dev/null | grep -q "10.42.0.1/24"; then
      if ! ip route show dev "$HUB_IFACE" 2>/dev/null | grep -q "10.42.0.0/24"; then
        echo ">>> adding connected route 10.42.0.0/24 dev $HUB_IFACE (NM noprefixroute workaround)"
        sudo ip route add "$TARGET_NET" dev "$HUB_IFACE" proto kernel scope link src 10.42.0.1
      fi
    fi

    ensure_forward
    echo
    show_status
    echo
    echo ">>> PC c now in clean-LAN mode. ping PC e/f from PC c should work."
    ;;

  status|"")
    show_status
    ;;

  *)
    echo "Usage: $0 abcd|clean_lan|status" >&2
    exit 1
    ;;
esac
