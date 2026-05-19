# comm_benchmark

Inter-PC communication bake-off harness for the bilateral-teleop project.
Mocks the leader↔follower message pattern (1 KiB payload at the same rate
as the real bilateral controller — 500 Hz default) and exposes pluggable
transports so we can compare jitter / throughput / loss across the
candidates surveyed in Mission 2.

The current scope is the **WAN-bound subset** that's autonomously
build-able and revertible. LAN-only candidates (TSN, RDMA, AF_XDP, NIC
IRQ pinning, etc.) are listed under TODO at the bottom.

## What's implemented now

| ID | Transport | Description |
|----|-----------|-------------|
| **B1** | `ros2_be`  | rclcpp + BEST_EFFORT QoS + KEEP_LAST 1 + VOLATILE durability, default SingleThreadedExecutor |
| **B6** | `ros2_mte` | same QoS + MultiThreadedExecutor + dedicated Reentrant callback group for the recv subscription, optional SCHED_FIFO on the executor worker |
| **E1** | `raw_udp`  | bare AF_INET / SOCK_DGRAM. struct memcpy on the wire, no RTPS, no discovery, optional SO_BUSY_POLL / SO_RCVBUF / SO_SNDBUF / SCHED_FIFO |
| **B7** | `zenoh_p2p`| same rclcpp+QoS as B1, but Zenoh session forced into **peer mode** (no central `rmw_zenohd` router). Both sides know each other's IP via `--peer-ip`, multicast scouting disabled. Requires `RMW_IMPLEMENTATION=rmw_zenoh_cpp`. |
| **B8** | `zenoh_router` | same rclcpp+QoS as B1, but Zenoh session forced into **client mode** with explicit `--router-ip` pointing at a `rmw_zenohd` daemon. Operator must start `rmw_zenohd` separately. Scouting disabled. This is the explicit "canonical" rmw_zenoh router baseline used to quantify router-hop cost vs `zenoh_p2p`. Requires `RMW_IMPLEMENTATION=rmw_zenoh_cpp`. |

The on-wire payload is exactly **1024 B** for every transport (24 B
measurement header + 144 B q/qd/tau_ext + 856 B padding). The
`static_assert(sizeof(Payload) == 1024)` in `payload.hpp` pins it;
the `comm_benchmark/Payload.msg` definition produces the same wire
size in CDR.

## Build

```bash
cd ~/colcon_ws
colcon build --packages-select comm_benchmark
source install/setup.bash
```

## Usage

Two binaries, one per side. Same flags. Run them simultaneously on
PC A and PC B (or both on one host with the loopback interface for a
single-machine sanity check).

```text
usage: bench_{a,b}
       --transport ros2_be|ros2_mte|raw_udp|zenoh_p2p|zenoh_router
       [--rate-hz 500] [--duration-sec 120] [--csv path]
       [--rt-priority 0]
       (raw_udp only) --peer-ip IP [--local-port P] [--peer-port P]
                      [--rcvbuf BYTES] [--sndbuf BYTES] [--busy-poll]
       (ros2_mte only) [--num-threads 2]
       (zenoh_p2p only) --peer-ip IP [--zenoh-port 7447]
       (zenoh_router only) --router-ip IP [--zenoh-port 7447]
                          (operator must start rmw_zenohd separately)
```

### Example — same-host loopback sanity check

```bash
# Terminal 1 (PC A side, on this host)
ros2 run comm_benchmark bench_a \
    --transport raw_udp --peer-ip 127.0.0.1 --local-port 18000 --peer-port 18001 \
    --rate-hz 500 --duration-sec 30 --csv /tmp/a.csv

# Terminal 2 (PC B side, same host)
ros2 run comm_benchmark bench_b \
    --transport raw_udp --peer-ip 127.0.0.1 --local-port 18001 --peer-port 18000 \
    --rate-hz 500 --duration-sec 30 --csv /tmp/b.csv
```

### Example — Zenoh peer-mode (P2P, no router)

```bash
# Both PCs first:
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=15

# PC a
ros2 run comm_benchmark bench_a \
    --transport zenoh_p2p --peer-ip 10.42.2.110 \
    --rate-hz 500 --duration-sec 30 --csv /tmp/a_p2p.csv

# PC d
ros2 run comm_benchmark bench_b \
    --transport zenoh_p2p --peer-ip 10.42.0.141 \
    --rate-hz 500 --duration-sec 30 --csv /tmp/d_p2p.csv
```

vs the default `ros2_be` (Zenoh client mode + bundled `rmw_zenohd` router):
the P2P variant should remove one router hop's worth of latency. TCP/7447 must
be open between the two PCs (see `network/setup_wg.sh` for the WG tunnel
that already covers this in the comm_benchmark mission).

### Example — Zenoh router mode (canonical client + rmw_zenohd)

The explicit "router baseline" for comparison against `zenoh_p2p` — pins
the session to client mode with a known `rmw_zenohd` endpoint, no
multicast/gossip discovery. The operator starts `rmw_zenohd` themselves
on the router host (usually one of the two PCs, often A).

```bash
# Both PCs first:
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=15

# PC a (also acts as router host)
ros2 run rmw_zenoh_cpp rmw_zenohd                      # leave running

# PC a — bench, connecting to local rmw_zenohd
ros2 run comm_benchmark bench_a \
    --transport zenoh_router --router-ip 127.0.0.1 \
    --rate-hz 500 --duration-sec 30 --csv /tmp/a_router.csv

# PC d — bench, connecting to PC a's rmw_zenohd
ros2 run comm_benchmark bench_b \
    --transport zenoh_router --router-ip 10.42.0.141 \
    --rate-hz 500 --duration-sec 30 --csv /tmp/d_router.csv
```

Diff vs `zenoh_p2p`: traffic goes bench_a → rmw_zenohd → bench_b
(two hops at the Zenoh layer instead of one). Use as the "before"
number when judging if `zenoh_p2p` actually wins.

### Example — `zenoh_router` across PC a↔d (over WG tunnel)

For the canonical router-mode baseline measured on the **same path**
the original 3 transports (raw_udp / ros2_be / ros2_mte) used —
PC a ↔ PC b ↔ corp/WG ↔ PC c ↔ PC d. The router runs on PC a
(simplest layout: bench_a is local to the router, bench_d is the
only one paying the tunnel cost).

```bash
# (PC c) — flip routing to a↔d mode first
#   This brings down the eno3np0 (e/f hub) NM connection and ensures
#   `10.42.0.0/24 via 10.99.0.1 dev wg0` is installed.
bash ~/colcon_ws/src/comm_benchmark/network/pc_c_mode.sh abcd

# (PC a) — verify reachability
ping -c 3 10.42.2.110

# (PC a) — shell 1: start rmw_zenohd (leave running)
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=15
ros2 run rmw_zenoh_cpp rmw_zenohd

# (PC a) — shell 2: bench_a, router = self
bash ~/colcon_ws/src/comm_benchmark/scripts/bench_one.sh \
     a zenoh_router 127.0.0.1 30 ~/bench_a_zenoh_router_abcd.csv

# (PC d) — bench_b, router = PC a (over WG)
bash ~/colcon_ws/src/comm_benchmark/scripts/bench_one.sh \
     b zenoh_router 10.42.0.141 30 ~/bench_d_zenoh_router_abcd.csv
```

After collection, swap back if you still want to use the clean-LAN
setup:

```bash
bash ~/colcon_ws/src/comm_benchmark/network/pc_c_mode.sh clean_lan
```

This `zenoh_router_abcd` number is the right "before" to compare
against `zenoh_p2p_abcd` and the three already-measured transports
on the same a↔d path.

### Single-shot runner — `scripts/bench_one.sh`

For interactive A/B (no for-loop matrix), useful in clean LAN setups
(e.g. **PC e ↔ switching hub ↔ PC f**) where you want to A/B individual
transports one at a time.

```bash
# PC e (peer = PC f at 192.168.1.11)
bash ~/colcon_ws/src/comm_benchmark/scripts/bench_one.sh a zenoh_p2p 192.168.1.11

# PC f (peer = PC e at 192.168.1.10)
bash ~/colcon_ws/src/comm_benchmark/scripts/bench_one.sh b zenoh_p2p 192.168.1.10
```

Args: `<a|b> <ros2_be|ros2_mte|raw_udp|zenoh_p2p|zenoh_router> <peer-or-router-ip> [duration_sec] [csv_path]`.
Defaults: 30 s, `~/bench_<role>_<transport>.csv`. Auto-applies the right
ports for `raw_udp`, `--peer-ip` for `zenoh_p2p`, and `--router-ip` for
`zenoh_router`. For `zenoh_router`, prints a warning if `rmw_zenohd` is
not running on this host (harmless if the router is on the other host).
Exports `ROS_DOMAIN_ID=15` and `RMW_IMPLEMENTATION=rmw_zenoh_cpp` unless
caller already set them.

### Example — across two PCs

Both PCs must be in the same DDS domain and use the same RMW
implementation. The project standard is:

```bash
# both PCs, every shell:
export ROS_DOMAIN_ID=15
export RMW_IMPLEMENTATION=rmw_zenoh_cpp   # or rmw_fastrtps_cpp — same on both sides
```

If PC B is missing an RMW that PC A has, install the matching package:

```bash
sudo apt install ros-jazzy-rmw-zenoh-cpp ros-jazzy-rmw-fastrtps-cpp
```

Then run the harness simultaneously on both sides:

```bash
# PC A — leader side
ros2 run comm_benchmark bench_a \
    --transport ros2_be \
    --rate-hz 500 --duration-sec 120 --csv pca_b1.csv

# PC B — follower side, simultaneously
ros2 run comm_benchmark bench_b \
    --transport ros2_be \
    --rate-hz 500 --duration-sec 120 --csv pcb_b1.csv
```

For `raw_udp`, no DDS configuration matters — just pass `--peer-ip` to
each side with the other PC's reachable IP.

### Determining LAN vs WAN before measurement

Quick assessment from PC A:

```bash
ping -c 20 <PC_B_IP>     # mean / mdev RTT
traceroute <PC_B_IP>     # hop count
ip route get <PC_B_IP>   # gateway path
ip a                     # local subnet (compare with PC_B_IP / mask)
```

Decision rule:

| signal | judgement | next step |
|---|---|---|
| same `/24` subnet, 1 hop, RTT < 1 ms, mdev < 0.5 ms | true LAN | skip tc netem |
| different subnet, 2–5 hops, RTT 1–5 ms, mdev < 1 ms | corporate intranet (router-routed but on-prem) | judge per signal — usually still good enough that tc netem is worth running to project to true WAN |
| 5+ hops or RTT > 10 ms or mdev > 1 ms | WAN-ish | tc netem strongly recommended |

If the corporate network turns out to be true LAN, **the WAN-mitigation
candidates surveyed in mission 2 become moot** — the candidate list is
designed for the eventual WAN deployment.

### Optional WAN emulation (tc netem)

Apply the WAN-baseline conditions to either PC's outgoing interface
*before* starting the bench. Marginal-worst-case from the mission spec:

```bash
sudo tc qdisc add dev <iface> root netem \
    delay 25ms 10ms distribution normal \
    loss 0.5% \
    duplicate 0.05% \
    reorder 0.1%

# ... run the bench ...

sudo tc qdisc del dev <iface> root
```

`<iface>` is e.g. `eth0`, `enp3s0`, `tailscale0` etc. Apply on one side
or both — the emulator delays the egress path, so applying on both adds
the delays.

## Output

Each side writes a CSV with one row per inbound message:

```
recv_ts_ns,peer_seq,peer_send_ts_ns,peer_acked_own_seq,computed_rtt_ns,inferred_loss
```

`computed_rtt_ns` is the round-trip latency for *our* `peer_acked_own_seq`,
i.e. how long it took for our own message to reach the peer and for the
peer to publish a packet that acknowledges it. **No clock synchronisation
required** — all timestamps in the RTT computation are local
`CLOCK_MONOTONIC`.

`inferred_loss` is the gap in the inbound peer-seq stream since the last
event.

### Summary tool

```bash
ros2 run comm_benchmark analyze.py /tmp/a.csv /tmp/b.csv
```

Prints p50 / p90 / p99 / p99.9 / max / mean / stdev RTT in microseconds
plus the inferred loss count.

### Retrieving PC B's CSV to PC A for analysis

```bash
# from PC A
scp <user>@<PC_B_IP>:~/pcb_*.csv /tmp/
ros2 run comm_benchmark analyze.py /tmp/pca_*.csv /tmp/pcb_*.csv
```

## Suggested test workflow

1. **Set common env on both PCs**:
   ```bash
   export ROS_DOMAIN_ID=15
   export RMW_IMPLEMENTATION=rmw_zenoh_cpp
   ```
2. **Determine LAN vs WAN** (see *Determining LAN vs WAN* above).
3. **(WAN/intranet only)** apply `tc netem` to a chosen interface on
    one side.
4. **Run the three transports back-to-back** on both PCs simultaneously,
    each for 120 s:
   ```bash
   for T in ros2_be ros2_mte raw_udp; do
       PEER_IP_FLAG=""
       [ "$T" = "raw_udp" ] && PEER_IP_FLAG="--peer-ip <peer_ip>"
       ros2 run comm_benchmark bench_a \
           --transport $T $PEER_IP_FLAG \
           --rate-hz 500 --duration-sec 120 \
           --csv pca_${T}.csv
   done
   ```
5. **Tear down `tc netem`** if applied.
6. **Pull PC B's CSVs to PC A** with `scp` and run `analyze.py`.

## Comparing candidates — workflow

The bake-off plan is to fix the WAN emulator settings (`tc netem`),
fix the payload and rate, and iterate the **`--transport`** flag. Each
run is independent; the per-transport CSVs feed into `analyze.py` for
side-by-side comparison.

Recommended ordering (cheapest first):

1. Baseline run with whatever RMW is currently set
   (`echo $RMW_IMPLEMENTATION`).
2. `--transport ros2_be` (B1) — same RMW, QoS swap.
3. `--transport ros2_mte` (B6) — adds executor + RT priority option.
4. `--transport raw_udp` (E1) — bypasses ROS2 layer entirely.
5. Optional: re-run the ROS2 transports with `RMW_IMPLEMENTATION` env
   var swapped (Cyclone, FastDDS, Zenoh peer mode) — this is the A1 /
   A2 / B4 candidates. Listed in TODO because Cyclone needs an apt
   install first.

## TODO — candidates not yet exercised here

These are listed in priority order (most likely to matter for WAN
first):

### 🟡 Level 3 — env var / config (one apt install away)

- [ ] **A1 rmw_cyclonedds** — `sudo apt install ros-jazzy-rmw-cyclonedds-cpp`,
      then `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` on both sides.
- [ ] **A2 rmw_fastrtps** — already installed; just swap env var.
      Useful as an additional baseline.
- [ ] **B2** DDS multicast → unicast — FastDDS profile XML
      (`FASTRTPS_DEFAULT_PROFILES_FILE`). Multicast often doesn't
      survive WAN routing anyway, so unicast is the realistic
      configuration.
- [ ] **B3** DDS thread / cache pre-allocation — same XML profile.
- [ ] **B4** rmw_zenoh peer mode — Zenoh `mode: peer` config file.
      Avoids the router hop where applicable.
- [ ] **B5** Zenoh batching off — Zenoh config file. Smaller batches
      means lower latency per message at the cost of throughput.

### 🟡 Level 4 — sysctl / ethtool (sudo, but read-backup-restore is safe)

- [ ] **C1** UDP socket buffer (`sysctl net.core.rmem_max / wmem_max`).
      For raw-udp, also pair with `--rcvbuf / --sndbuf` to use the new
      ceiling.
- [ ] **VPN1** Tailscale set-up on both PCs (NAT-traversing overlay).
      Gives the harness a routable peer IP without ISP-router port
      forwarding.

### 🔵 Level 4 — bigger lifts

- [ ] **E2 SCTP** — `modprobe sctp` + `libsctp-dev`. Multi-stream,
      selective ARQ.
- [ ] **D1 AF_XDP** — libbpf + custom eBPF program. NIC→userspace
      zero-copy. Major code addition; only worth it if Levels 1–3
      hit a clear ceiling.

### 🟢 Library candidates — apt install + small wrapper

- [ ] **E5 NNG** — `apt install libnng-dev`.
- [ ] **E6 0MQ** (TCP transport, drop PGM since multicast doesn't work
      over WAN) — `apt install libzmq3-dev`.
- [ ] **E7 QUIC** — msquic or quiche. UDP+TLS+streams, designed for
      variable-latency networks.
- [ ] **E8 SRT** — `apt install libsrt-dev`. Reliable UDP for
      real-time-over-WAN.
- [ ] **E9 RIST** — `apt install librist-dev`. Sister protocol of SRT.
- [ ] **E4 KCP** — single-file vendor (no apt).

### ⚪ Out of WAN scope (LAN-only) — recorded for completeness

- LAN-µs tuning: SO_BUSY_POLL via sysctl, NIC IRQ pinning, NIC offload
  tuning (ethtool), tc qdisc shaping, isolcpus. **Effects are µs-scale
  and dominated by ISP-router ms-scale jitter once we cross WAN.**
- Kernel bypass: AF_XDP at full kernel-bypass scale, DPDK, OpenOnload.
- LAN-only fabrics: RDMA / RoCE, InfiniBand, TSN (802.1Qbv/Qbu/CB).
- Industrial fieldbuses: EtherCAT, PROFINET, EtherNet/IP, POWERLINK.
- LAN topology / hardware: direct point-to-point, dedicated RT NIC,
  10/25 Gbps NIC, industrial RT switch.

These are kept in the discussion record (mission 2 working notes) but
will only be revisited if the production deployment ever returns to a
single LAN.

### 🟣 Next phase — algorithm-level mitigations

Independent of transport. Listed here so they don't get lost.

- [ ] **I1** Predictive transmission — sender includes
      `q + q̇·Δt + ½·q̈·Δt²` extrapolation; receiver uses it during gaps.
- [ ] **I2** Wave variables / scattering (Niemeyer-Slotine 1991) —
      passivity-preserving for arbitrary delay.
- [ ] **I3** TDPA — already coded as `EnergyTank` in
      `ur10e_teleop_control_hybrid_cpp`; activate and measure.

## File map

```
comm_benchmark/
├── CMakeLists.txt
├── package.xml
├── README.md
├── msg/Payload.msg
├── include/comm_benchmark/
│   ├── cli.hpp
│   ├── payload.hpp
│   ├── stats.hpp
│   ├── transport.hpp
│   └── transports/
│       ├── raw_udp.hpp
│       ├── ros2_be.hpp
│       └── ros2_mte.hpp
├── src/
│   ├── bench_a_main.cpp
│   ├── bench_b_main.cpp
│   ├── bench_run.cpp
│   ├── cli.cpp
│   ├── stats.cpp
│   └── transports/
│       ├── raw_udp.cpp
│       ├── ros2_be.cpp
│       └── ros2_mte.cpp
└── scripts/
    └── analyze.py
```
