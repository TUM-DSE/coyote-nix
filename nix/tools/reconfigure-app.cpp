#include <coyote/cRcnfg.hpp>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {

struct options {
  std::uint32_t device = 0;
  std::uint32_t vfpga = 0;
  bool dry_run = false;
  std::string image;
};

void usage(const char *program) {
  std::cerr << "Usage: " << program
            << " [--device ID] [--vfpga ID] [--dry-run] image.bin|image.pdi\n"
            << "Load one application partial image through an already active "
               "Coyote driver.\n";
}

std::uint32_t parse_id(const std::string &value, const char *option) {
  std::size_t consumed = 0;
  unsigned long long parsed = 0;
  try {
    parsed = std::stoull(value, &consumed, 10);
  } catch (const std::exception &) {
    throw std::runtime_error(std::string(option) +
                             " requires a non-negative integer");
  }
  if (consumed != value.size() ||
      parsed > std::numeric_limits<std::uint32_t>::max()) {
    throw std::runtime_error(std::string(option) +
                             " is outside the uint32 range");
  }
  return static_cast<std::uint32_t>(parsed);
}

bool has_suffix(const std::string &value, const std::string &suffix) {
  return value.size() >= suffix.size() &&
         value.compare(value.size() - suffix.size(), suffix.size(), suffix) ==
             0;
}

options parse_options(int argc, char **argv) {
  options result;
  bool positional_only = false;
  for (int index = 1; index < argc; ++index) {
    const std::string argument(argv[index]);
    if (!positional_only && argument == "--") {
      positional_only = true;
    } else if (!positional_only && (argument == "-h" || argument == "--help")) {
      usage(argv[0]);
      std::exit(0);
    } else if (!positional_only && argument == "--dry-run") {
      result.dry_run = true;
    } else if (!positional_only &&
               (argument == "--device" || argument == "--vfpga")) {
      if (index + 1 >= argc) {
        throw std::runtime_error(argument + " requires a value");
      }
      const auto value = parse_id(argv[++index], argument.c_str());
      if (argument == "--device") {
        result.device = value;
      } else {
        if (value >
            static_cast<std::uint32_t>(std::numeric_limits<int>::max())) {
          throw std::runtime_error(
              "--vfpga is outside the supported int range");
        }
        result.vfpga = value;
      }
    } else if (!positional_only && argument.rfind("--", 0) == 0) {
      throw std::runtime_error("unknown option: " + argument);
    } else if (result.image.empty()) {
      result.image = argument;
    } else {
      throw std::runtime_error("more than one application image was provided");
    }
  }

  if (result.image.empty()) {
    throw std::runtime_error("an application partial image is required");
  }
  if (!has_suffix(result.image, ".bin") && !has_suffix(result.image, ".pdi")) {
    throw std::runtime_error("application image must end in .bin or .pdi");
  }

  std::ifstream image(result.image, std::ios::binary | std::ios::ate);
  if (!image) {
    throw std::runtime_error("application image cannot be opened: " +
                             result.image);
  }
  if (image.tellg() <= 0) {
    throw std::runtime_error("application image is empty: " + result.image);
  }
  return result;
}

} // namespace

int main(int argc, char **argv) {
  try {
    const auto options = parse_options(argc, argv);
    if (options.dry_run) {
      std::cout << "COYOTE_RECONFIGURE_APP_READY"
                << " device=" << options.device << " vfpga=" << options.vfpga
                << " image=" << options.image << '\n';
      return 0;
    }

    coyote::cRcnfg reconfiguration(options.device);
    reconfiguration.reconfigureApp(options.image,
                                   static_cast<int>(options.vfpga));
    std::cout << "COYOTE_RECONFIGURE_APP_DONE"
              << " device=" << options.device << " vfpga=" << options.vfpga
              << " image=" << options.image << '\n';
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "reconfigure-app: " << error.what() << '\n';
    usage(argv[0]);
    return 1;
  }
}
