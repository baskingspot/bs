//! A limit below 80 bytes, which the cached
//! findings do not cover: the report step
//! scans the source. Line 6 is 61 bytes, line
//! 7 is 60, and line 9's finding is ignored.
test {
    _ = "..................................................";
    _ = ".................................................";
    // ziglint-ignore: Z024
    _ = "................................................................";
}
