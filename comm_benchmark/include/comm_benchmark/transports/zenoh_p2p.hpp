#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "comm_benchmark/transport.hpp"
#include "comm_benchmark/transports/ros2_be.hpp"

namespace comm_benchmark {

// Zenoh peer-mode (true P2P) transport.
//
// Same on-wire publisher/subscriber as Ros2BeTransport (rclcpp +
// BEST_EFFORT QoS + KEEP_LAST 1 + VOLATILE), but the underlying Zenoh
// session is forced into 'peer' mode with explicit unicast connect /
// listen endpoints — no central rmw_zenohd router involved.
//
// Implementation: writes a small Zenoh JSON5 config to /tmp and exports
// `ZENOH_SESSION_CONFIG_URI` BEFORE rclcpp::init, so rmw_zenoh_cpp picks
// it up at startup. Multicast scouting is disabled — both sides must
// know each other's IP (via --peer-ip) and the same Zenoh listen port
// (default 7447).
//
// Requires `RMW_IMPLEMENTATION=rmw_zenoh_cpp`. Behaviour with FastDDS or
// other RMW is undefined (env var is silently ignored).
class ZenohP2pTransport : public Transport {
 public:
  struct Config {
    std::string node_name;
    std::string out_topic;
    std::string in_topic;
    std::string peer_ip;          // peer's IP (reuse --peer-ip)
    uint16_t    zenoh_port{7447}; // local + peer Zenoh listen port
  };

  explicit ZenohP2pTransport(const Config& cfg);
  ~ZenohP2pTransport() override;

  void start() override;
  void stop() override;
  void send(const Payload& msg) override;
  void set_recv_callback(RecvCallback cb) override;
  std::string name() const override { return "zenoh_p2p"; }

 private:
  Config cfg_;
  std::unique_ptr<Ros2BeTransport> impl_;
};

}  // namespace comm_benchmark
