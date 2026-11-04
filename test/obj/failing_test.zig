//! A test that fails when it runs: `bs test -fno-emit-bin` must only
//! compile it, as upstream does.
test "fails" {
    return error.RanTheTest;
}
