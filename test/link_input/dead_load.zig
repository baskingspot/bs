// A discarded load still links the declaration it reads, as upstream's
// Debug code does, so the undefined extern in `p`'s data is an error.
extern var nope: u8;
var p: *u8 = &nope;
pub fn main() void {
    _ = p.*;
}
