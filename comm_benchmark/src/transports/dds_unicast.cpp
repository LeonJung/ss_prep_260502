#include "comm_benchmark/transports/dds_unicast.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace comm_benchmark {

namespace {

// Write a Fast DDS XML profile to /tmp that:
//   - disables multicast metatraffic (empty multicast list)
//   - binds metatraffic unicast on 0.0.0.0 (auto port assignment)
//   - registers `peer_ip` in initialPeersList so the participant
//     contacts the peer at startup
// Returns the absolute path so callers can export
// FASTRTPS_DEFAULT_PROFILES_FILE.
std::string write_fastdds_unicast_profile(const std::string& peer_ip) {
  char path[128];
  std::snprintf(path, sizeof(path),
                "/tmp/comm_bench_dds_unicast_%d.xml",
                static_cast<int>(::getpid()));

  std::ostringstream cfg;
  cfg << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      << "<profiles xmlns=\"http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles\">\n"
      << "  <participant profile_name=\"participant_unicast\" is_default_profile=\"true\">\n"
      << "    <rtps>\n"
      << "      <builtin>\n"
      << "        <metatrafficUnicastLocatorList>\n"
      << "          <locator>\n"
      << "            <udpv4>\n"
      << "              <address>0.0.0.0</address>\n"
      << "            </udpv4>\n"
      << "          </locator>\n"
      << "        </metatrafficUnicastLocatorList>\n"
      << "        <metatrafficMulticastLocatorList>\n"
      << "        </metatrafficMulticastLocatorList>\n"
      << "        <initialPeersList>\n"
      << "          <locator>\n"
      << "            <udpv4>\n"
      << "              <address>" << peer_ip << "</address>\n"
      << "            </udpv4>\n"
      << "          </locator>\n"
      << "        </initialPeersList>\n"
      << "      </builtin>\n"
      << "    </rtps>\n"
      << "  </participant>\n"
      << "</profiles>\n";

  std::ofstream f(path);
  f << cfg.str();
  f.close();
  return path;
}

}  // namespace

DdsUnicastTransport::DdsUnicastTransport(const Config& cfg) : cfg_(cfg) {
  // setenv must happen before rclcpp::init so rmw_fastrtps_cpp picks it
  // up at startup. The bench runner constructs the transport before
  // calling rclcpp::init, so this ordering holds.
  const std::string path = write_fastdds_unicast_profile(cfg.peer_ip);
  ::setenv("FASTRTPS_DEFAULT_PROFILES_FILE", path.c_str(), 1);

  Ros2BeTransport::Config base{cfg.node_name, cfg.out_topic, cfg.in_topic};
  impl_ = std::make_unique<Ros2BeTransport>(base);
}

DdsUnicastTransport::~DdsUnicastTransport() = default;

void DdsUnicastTransport::start() { impl_->start(); }
void DdsUnicastTransport::stop()  { impl_->stop(); }
void DdsUnicastTransport::send(const Payload& msg) { impl_->send(msg); }
void DdsUnicastTransport::set_recv_callback(RecvCallback cb) {
  impl_->set_recv_callback(std::move(cb));
}

}  // namespace comm_benchmark
