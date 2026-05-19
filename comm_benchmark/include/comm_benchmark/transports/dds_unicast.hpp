#pragma once

#include <memory>
#include <string>

#include "comm_benchmark/transport.hpp"
#include "comm_benchmark/transports/ros2_be.hpp"

namespace comm_benchmark {

// Tier-1 candidate: explicit DDS unicast discovery.
//
// Same on-wire publisher/subscriber as Ros2BeTransport (rclcpp +
// BEST_EFFORT QoS + KEEP_LAST 1 + VOLATILE), but the underlying RMW
// is pinned to Fast DDS with an XML profile that:
//   - empties metatrafficMulticastLocatorList (no mcast discovery)
//   - sets initialPeersList to the peer's IP (explicit unicast)
//
// Rationale: in the corp WG environment (a↔d), multicast traffic
// rarely traverses the corporate router, so default DDS discovery
// is non-deterministic and may take random fallback paths. Explicit
// unicast peer list eliminates that ambiguity and pins discovery
// traffic to a known unicast path.
//
// Requires `RMW_IMPLEMENTATION=rmw_fastrtps_cpp`. The transport
// writes the profile to /tmp and exports
// `FASTRTPS_DEFAULT_PROFILES_FILE` BEFORE rclcpp::init.
class DdsUnicastTransport : public Transport {
 public:
  struct Config {
    std::string node_name;
    std::string out_topic;
    std::string in_topic;
    std::string peer_ip;          // peer's IP (reuse --peer-ip)
  };

  explicit DdsUnicastTransport(const Config& cfg);
  ~DdsUnicastTransport() override;

  void start() override;
  void stop() override;
  void send(const Payload& msg) override;
  void set_recv_callback(RecvCallback cb) override;
  std::string name() const override { return "dds_unicast"; }

 private:
  Config cfg_;
  std::unique_ptr<Ros2BeTransport> impl_;
};

}  // namespace comm_benchmark
