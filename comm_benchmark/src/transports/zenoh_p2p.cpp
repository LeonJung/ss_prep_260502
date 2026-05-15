#include "comm_benchmark/transports/zenoh_p2p.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

namespace comm_benchmark {

namespace {

// Write a Zenoh JSON5 peer-mode config to a stable path under /tmp and
// return that path. The config:
//   - mode: peer (no router)
//   - connect: explicit unicast endpoint to the peer
//   - listen: bind on 0.0.0.0 at the same port (so the peer can connect to us too)
//   - scouting.multicast: disabled (corp/WG environments rarely pass mcast)
//
// Path is per-PID so two roles on the same host don't clobber each other.
std::string write_peer_config(const std::string& peer_ip, uint16_t port) {
  char path[128];
  std::snprintf(path, sizeof(path),
                "/tmp/comm_bench_zenoh_p2p_%d.json5",
                static_cast<int>(::getpid()));

  std::ostringstream cfg;
  cfg << "{\n"
      << "  mode: \"peer\",\n"
      << "  connect: { endpoints: [\"tcp/" << peer_ip << ":" << port << "\"] },\n"
      << "  listen:  { endpoints: [\"tcp/0.0.0.0:" << port << "\"] },\n"
      << "  scouting: { multicast: { enabled: false }, gossip: { enabled: false } },\n"
      << "}\n";

  std::ofstream f(path);
  f << cfg.str();
  f.close();
  return path;
}

}  // namespace

ZenohP2pTransport::ZenohP2pTransport(const Config& cfg) : cfg_(cfg) {
  // CRITICAL: setenv must happen before rclcpp::init so rmw_zenoh_cpp
  // sees the override. The bench runner constructs the transport before
  // calling rclcpp::init, so this ordering holds.
  const std::string path = write_peer_config(cfg.peer_ip, cfg.zenoh_port);
  ::setenv("ZENOH_SESSION_CONFIG_URI", path.c_str(), 1);

  // Build the underlying ros2_be transport — same QoS/executor as the B1
  // baseline. Only the Zenoh session under it is forced to peer mode.
  Ros2BeTransport::Config base{cfg.node_name, cfg.out_topic, cfg.in_topic};
  impl_ = std::make_unique<Ros2BeTransport>(base);
}

ZenohP2pTransport::~ZenohP2pTransport() = default;

void ZenohP2pTransport::start() { impl_->start(); }
void ZenohP2pTransport::stop()  { impl_->stop(); }
void ZenohP2pTransport::send(const Payload& msg) { impl_->send(msg); }
void ZenohP2pTransport::set_recv_callback(RecvCallback cb) {
  impl_->set_recv_callback(std::move(cb));
}

}  // namespace comm_benchmark
