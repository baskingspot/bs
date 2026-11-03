pub fn main() void {
    var x: u32 = 1;
}

// error
// args: --error-format=json
// {"code":"unused","file":"json.zig","line":2,"col":9,"span":[29,30],"msg":"unused local variable","src":"var x: u32 = 1;"}
// {"summary":{"errors":1}}
