// The executable's operator new is the shared library's (cxx_new.cpp),
// not libc++'s: a name a shared library defines pulls no member from the
// C++ runtime's archives, which upstream's linker sees after it.
#include <cstdio>
int new_count();
int main() {
    int *p = new int(41);
    std::printf("%d %d\n", *p + 1, new_count());
    delete p;
    return 0;
}
