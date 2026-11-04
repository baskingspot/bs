#include "merge.h"
#include <cstdio>
int f1(int);
int main() {
    bump();
    try {
        f1(-1);
    } catch (std::exception &e) {
        std::printf("caught %s\n", e.what());
    }
    int a = f1(3);
    int b = twice(4);
    int c = S<int>::count;
    std::printf("%d %d %d %d\n", a, b, c, bump());
}
