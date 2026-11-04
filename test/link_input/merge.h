// Inline functions, a template's static member and a function-local
// static, which each C++ object defines in a COMDAT group.
#include <stdexcept>
inline int twice(int x) {
    if (x < 0) throw std::runtime_error("neg");
    return 2 * x;
}
template <typename T> struct S {
    static int count;
    static T get(T v) { count++; return v + 1; }
};
template <typename T> int S<T>::count = 0;
inline int bump() { static int u = 0; return ++u; }
