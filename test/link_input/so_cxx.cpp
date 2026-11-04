// A shared library of C++ only (`bs build-lib -dynamic -lc++ --version`):
// libc++ is built into it, as upstream builds it, and its soname is
// libsxx.so.1 (build.zig, `addLinkInputTests`); so_cxx_main.zig loads it.
#include <stdexcept>
#include <string>

extern "C" int sxx_run(int n) {
    try {
        if (n > 0) throw std::runtime_error("boom " + std::to_string(n));
        return -1;
    } catch (const std::exception &e) {
        return static_cast<int>(std::string(e.what()).size());
    }
}
