#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "comm_benchmark/transport.hpp"
#include "comm_benchmark/transports/ros2_be.hpp"

namespace comm_benchmark {

// Zenoh router (client) mode transport.
//
// Same on-wire publisher/subscriber as Ros2BeTransport, but the
// underlying Zenoh session is forced into 'client' mode with an
// explicit connect endpoint to a `rmw_zenohd` instance running on
// `--router-ip`. Multicast/gossip scouting is disabled so there is
// no ambiguity about how the session is discovered.
//
// Operator responsibility: start `rmw_zenohd` (e.g.
// `ros2 run rmw_zenoh_cpp rmw_zenohd`) on the router host BEFORE
// launching bench_a / bench_b. Both bench processes must point at
// the same router-ip:zenoh-port.
//
// Purpose: explicit, reproducible baseline that goes through the
// canonical rmw_zenoh_cpp router — the "원래 하던 방식" — to compare
// against zenoh_p2p (no router) and quantify the router-hop cost.
//
// Requires `RMW_IMPLEMENTATION=rmw_zenoh_cpp`.
class ZenohRouterTransport : public Transport {
 public:
  struct Config {
    std::string node_name;
    std::string out_topic;
    std::string in_topic;
    std::string router_ip;          // rmw_zenohd host (reuse --router-ip)
    uint16_t    zenoh_port{7447};   // rmw_zenohd listen port
  };

  explicit ZenohRouterTransport(const Config& cfg);
  ~ZenohRouterTransport() override;

  void start() override;
  void stop() override;
  void send(const Payload& msg) override;
  void set_recv_callback(RecvCallback cb) override;
  std::string name() const override { return "zenoh_router"; }

 private:
  Config cfg_;
  std::unique_ptr<Ros2BeTransport> impl_;
};

}  // namespace comm_benchmark
