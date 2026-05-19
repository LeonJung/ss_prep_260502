#!/usr/bin/env bash
# bench_one.sh — run ONE comm_benchmark transport (no for-loop).
#
# Designed for the PC e ↔ switching-hub ↔ PC f setup (clean LAN, no
# corp routing or WG tunnel) where you want to A/B individual
# transports interactively rather than batch a full matrix.
#
# Usage:
#   bash bench_one.sh <role> <transport> <peer-or-router-ip> [duration_sec] [csv_path]
#
#   role               : a | b      (default ports for raw_udp picked accordingly)
#   transport          : ros2_be | ros2_mte | raw_udp | zenoh_p2p | zenoh_router | dds_unicast
#   peer-or-router-ip  : for raw_udp / zenoh_p2p / dds_unicast : peer's IP
#                        for zenoh_router       : host running rmw_zenohd
#                        for ros2_be / ros2_mte : ignored (pass any token)
#   duration           : optional, default 30
#   csv_path           : optional, default ~/bench_<role>_<transport>.csv
#
# Examples (PC e at 192.168.1.10, PC f at 192.168.1.11):
#
#   # PC e — Zenoh peer mode (no router)
#   bash bench_one.sh a zenoh_p2p 192.168.1.11
#   # PC f
#   bash bench_one.sh b zenoh_p2p 192.168.1.10
#
#   # PC e — Zenoh client mode (requires `rmw_zenohd` running, e.g. on PC e itself)
#   #   On PC e (separate shell, BEFORE running bench):
#   #     RMW_IMPLEMENTATION=rmw_zenoh_cpp ros2 run rmw_zenoh_cpp rmw_zenohd
#   bash bench_one.sh a zenoh_router 192.168.1.10        # PC e (router = self)
#   bash bench_one.sh b zenoh_router 192.168.1.10        # PC f (router = PC e)
#
# For raw_udp, default ports:  A binds 18000 → B:18001, B binds 18001 → A:18000
# For zenoh_p2p / zenoh_router, both sides use TCP/7447

set -e

ROLE="${1:-}"
TRANSPORT="${2:-}"
PEER_IP="${3:-}"
DURATION="${4:-30}"
CSV="${5:-$HOME/bench_${ROLE}_${TRANSPORT}.csv}"

if [[ -z "$ROLE" || -z "$TRANSPORT" || -z "$PEER_IP" ]]; then
  echo "Usage: $0 <a|b> <ros2_be|ros2_mte|raw_udp|zenoh_p2p|zenoh_router> <peer-or-router-ip> [duration] [csv]" >&2
  exit 1
fi
case "$ROLE" in a|b) ;; *) echo "role must be a or b" >&2; exit 1 ;; esac
case "$TRANSPORT" in
  ros2_be|ros2_mte|raw_udp|zenoh_p2p|zenoh_router|dds_unicast) ;;
  *) echo "unknown transport: $TRANSPORT" >&2; exit 1 ;;
esac

# Default ROS env (caller can override before invoking).
# dds_unicast requires Fast DDS RMW to honor the XML profile we write;
# other transports default to Zenoh as before.
: "${ROS_DOMAIN_ID:=15}"
if [[ "$TRANSPORT" == "dds_unicast" ]]; then
  : "${RMW_IMPLEMENTATION:=rmw_fastrtps_cpp}"
else
  : "${RMW_IMPLEMENTATION:=rmw_zenoh_cpp}"
fi
export ROS_DOMAIN_ID RMW_IMPLEMENTATION

# Per-transport flags
case "$TRANSPORT" in
  raw_udp)
    if [[ "$ROLE" == "a" ]]; then
      EXTRA="--peer-ip $PEER_IP --local-port 18000 --peer-port 18001"
    else
      EXTRA="--peer-ip $PEER_IP --local-port 18001 --peer-port 18000"
    fi
    ;;
  zenoh_p2p)
    EXTRA="--peer-ip $PEER_IP"
    ;;
  zenoh_router)
    EXTRA="--router-ip $PEER_IP"
    if ! pgrep -af rmw_zenohd >/dev/null; then
      echo ">>> WARNING: rmw_zenohd not detected on this host." >&2
      echo ">>>          If the router is on a DIFFERENT host ($PEER_IP), this is fine — make sure it's running there." >&2
      echo ">>>          If the router was supposed to be on this host, start it first:" >&2
      echo ">>>            RMW_IMPLEMENTATION=rmw_zenoh_cpp ros2 run rmw_zenoh_cpp rmw_zenohd" >&2
    fi
    ;;
  dds_unicast)
    EXTRA="--peer-ip $PEER_IP"
    if [[ "$RMW_IMPLEMENTATION" != "rmw_fastrtps_cpp" ]]; then
      echo ">>> WARNING: RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION but dds_unicast" >&2
      echo ">>>          generates a Fast DDS XML profile. Forcing rmw_fastrtps_cpp." >&2
      export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
    fi
    ;;
  *)
    EXTRA=""
    ;;
esac

BIN="bench_${ROLE}"

echo ">>> ROS_DOMAIN_ID=$ROS_DOMAIN_ID  RMW=$RMW_IMPLEMENTATION"
echo ">>> ros2 run comm_benchmark $BIN --transport $TRANSPORT $EXTRA \\"
echo "        --rate-hz 500 --duration-sec $DURATION --csv $CSV"
echo

ros2 run comm_benchmark "$BIN" \
  --transport "$TRANSPORT" \
  $EXTRA \
  --rate-hz 500 --duration-sec "$DURATION" --csv "$CSV"
