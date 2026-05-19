#include "comm_benchmark/transports/zenoh_router.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace comm_benchmark {

namespace {

// Write a Zenoh JSON5 client-mode config to a per-PID path under /tmp
// and return that path. The config:
//   - mode: client (connects to a running rmw_zenohd)
//   - connect: explicit unicast endpoint to the router
//   - scouting (multicast + gossip): disabled — no implicit discovery
std::string write_client_config(const std::string& router_ip, uint16_t port) {
  char path[128];
  std::snprintf(path, sizeof(path),
                "/tmp/comm_bench_zenoh_router_%d.json5",
                static_cast<int>(::getpid()));

  std::ostringstream cfg;
  cfg << "{\n"
      << "  mode: \"client\",\n"
      << "  connect: { endpoints: [\"tcp/" << router_ip << ":" << port << "\"] },\n"
      << "  scouting: { multicast: { enabled: false }, gossip: { enabled: false } },\n"
      << "}\n";

  std::ofstream f(path);
  f << cfg.str();
  f.close();
  return path;
}

}  // namespace

ZenohRouterTransport::ZenohRouterTransport(const Config& cfg) : cfg_(cfg) {
  // CRITICAL: setenv must happen before rclcpp::init so rmw_zenoh_cpp
  // sees the override. The bench runner constructs the transport before
  // calling rclcpp::init, so this ordering holds.
  const std::string path = write_client_config(cfg.router_ip, cfg.zenoh_port);
  ::setenv("ZENOH_SESSION_CONFIG_URI", path.c_str(), 1);

  Ros2BeTransport::Config base{cfg.node_name, cfg.out_topic, cfg.in_topic};
  impl_ = std::make_unique<Ros2BeTransport>(base);
}

ZenohRouterTransport::~ZenohRouterTransport() = default;

void ZenohRouterTransport::start() { impl_->start(); }
void ZenohRouterTransport::stop()  { impl_->stop(); }
void ZenohRouterTransport::send(const Payload& msg) { impl_->send(msg); }
void ZenohRouterTransport::set_recv_callback(RecvCallback cb) {
  impl_->set_recv_callback(std::move(cb));
}

}  // namespace comm_benchmark
