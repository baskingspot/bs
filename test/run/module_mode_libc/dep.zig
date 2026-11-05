pub fn mode() [:0]const u8 {
    return @tagName(@import("builtin").mode);
}
