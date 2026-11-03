const Point = struct { x: f32, y: bool };

pub fn main() void {
    const p: Point = @import("zon_point.zon");
    _ = p;
}

// error
// zon_point.zon:3:10: error[type-mismatch]: expected type 'bool'
//   | .y = 2,
//   note zon_import.zig:4:30: imported here
// 1 error
