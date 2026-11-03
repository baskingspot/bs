const buffer_size = 64;

fn capture(items: []const u32) u32 {
    var sum: u32 = 0;
    for (items) |item| sum += itme;
    return sum;
}

fn param(count: usize) usize {
    return cuont + 1;
}

fn container() usize {
    return bufer_size;
}

pub fn main() void {
    _ = capture(&.{});
    _ = param(1);
    _ = container();
}

// error
// undeclared.zig:5:31: error[undeclared]: use of undeclared identifier 'itme'
//   | for (items) |item| sum += itme;
//   candidates: item
//   fix? undeclared.zig:5:31-5:35: "item"
// undeclared.zig:10:12: error[undeclared]: use of undeclared identifier 'cuont'
//   | return cuont + 1;
//   candidates: count
//   fix? undeclared.zig:10:12-10:17: "count"
// undeclared.zig:14:12: error[undeclared]: use of undeclared identifier 'bufer_size'
//   | return bufer_size;
//   candidates: buffer_size
//   fix? undeclared.zig:14:12-14:22: "buffer_size"
// 3 errors
