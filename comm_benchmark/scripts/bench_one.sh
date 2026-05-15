#!/usr/bin/env bash
# bench_one.sh — run ONE comm_benchmark transport (no for-loop).
#
# Designed for the PC e ↔ switching-hub ↔ PC f setup (clean LAN, no
# corp routing or WG tunnel) where you want to A/B individual
# transports interactively rather than batch a full matrix.
#
# Usage:
#   bash bench_one.sh <role> <transport> <peer-ip> [duration_sec] [csv_path]
#
#   role        : a | b      (default ports for raw_udp picked accordingly)
#   transport   : ros2_be | ros2_mte | raw_udp | zenoh_p2p
#   peer-ip     : peer's IP (the OTHER PC's address on the shared switch)
#   duration    : optional, default 30
#   csv_path    : optional, default ~/bench_<role>_<transport>.csv
#
# Examples (PC e at 192.168.1.10, PC f at 192.168.1.11):
#
#   # PC e
#   bash bench_one.sh a zenoh_p2p 192.168.1.11
#
#   # PC f
#   bash bench_one.sh b zenoh_p2p 192.168.1.10
#
# For raw_udp, default ports:  A binds 18000 → B:18001, B binds 18001 → A:18000
# For zenoh_p2p,            both sides listen on TCP/7447

set -e

ROLE="${1:-}"
TRANSPORT="${2:-}"
PEER_IP="${3:-}"
DURATION="${4:-30}"
CSV="${5:-$HOME/bench_${ROLE}_${TRANSPORT}.csv}"

if [[ -z "$ROLE" || -z "$TRANSPORT" || -z "$PEER_IP" ]]; then
  echo "Usage: $0 <a|b> <ros2_be|ros2_mte|raw_udp|zenoh_p2p> <peer-ip> [duration] [csv]" >&2
  exit 1
fi
case "$ROLE" in a|b) ;; *) echo "role must be a or b" >&2; exit 1 ;; esac
case "$TRANSPORT" in
  ros2_be|ros2_mte|raw_udp|zenoh_p2p) ;;
  *) echo "unknown transport: $TRANSPORT" >&2; exit 1 ;;
esac

# Default ROS env (caller can override before invoking)
: "${ROS_DOMAIN_ID:=15}"
: "${RMW_IMPLEMENTATION:=rmw_zenoh_cpp}"
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
