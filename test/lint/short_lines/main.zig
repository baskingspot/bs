test {
    _ = @import("lines.zig");
}

// error
// lines.zig:6:61: error[style, Z024]: line exceeds 60 bytes (61 bytes)
//   | _ = "..................................................";
// 1 error
