// A C++ source of a -lc++ executable (build.zig, `addLinkInputTests`):
// exceptions thrown through frames with cleanups and caught by type, RTTI,
// a static constructor, thread_local with a dynamic initializer, and the
// standard library. Upstream prints the same.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <typeinfo>
#include <vector>

extern "C" int zig_add(int, int);

struct Base {
    virtual ~Base() {}
    virtual int value() const { return 1; }
};
struct Derived : Base {
    int value() const override { return 7; }
};

static int ctor_ran = 0;
static struct Init {
    Init() { ctor_ran = zig_add(40, 2); }
} init_obj;

thread_local std::string tls_str = std::string("tls") + std::to_string(ctor_ran);

static int depth = 0;
static void thrower(int n) {
    std::string cleanup = "frame";
    depth += 1;
    if (n == 0) throw std::runtime_error("boom at depth " + std::to_string(depth));
    thrower(n - 1);
}

extern "C" int cxx_run(void) {
    int r = 0;
    try {
        thrower(3);
    } catch (const std::logic_error &) {
        r += 1000;
    } catch (const std::exception &e) {
        std::printf("caught: %s\n", e.what());
        r += 1;
    }
    try {
        throw 5;
    } catch (int v) {
        r += v * 10;
    }
    Base *b = new Derived;
    if (dynamic_cast<Derived *>(b) && typeid(*b) == typeid(Derived) && b->value() == 7) r += 100;
    std::printf("type: %s\n", typeid(*b).name());
    delete b;
    std::vector<int> v{3, 1, 2};
    int sum = 0;
    for (int x : v) sum += x;
    tls_str += "!";
    std::printf("ctor %d, tls %s, sum %d\n", ctor_ran, tls_str.c_str(), sum);
    return r;
}
