// A type outlives the analysis that declares a comptime var, so its
// sentinel or field default value may not point to one.
fn arraySentinel() void {
    comptime var a: u8 = 0;
    _ = [0:&a]*u8;
}
fn sliceSentinel() void {
    comptime var a: u8 = 0;
    _ = [:&a]*u8;
}
fn reifiedSentinel() void {
    comptime var a: u8 = 0;
    _ = @Pointer(.many, .{}, *u8, &a);
}
fn tupleDefault() void {
    comptime var a: u8 = 0;
    _ = struct { comptime *u8 = &a };
}
fn reifiedDefault() void {
    comptime var a: u8 = 0;
    _ = @Struct(.auto, null, &.{"foo"}, &.{*u8}, &.{.{ .default_value_ptr = @ptrCast(&&a) }});
}

pub fn main() void {
    arraySentinel();
    sliceSentinel();
    reifiedSentinel();
    tupleDefault();
    reifiedDefault();
}

// error
// comptime_var_type.zig:5:12: error[comptime-var-escape]: sentinel contains reference to comptime var
//   | _ = [0:&a]*u8;
//   note comptime_var_type.zig:5:12: 'sentinel' points to a comptime var, which is not available after the analysis that declares it
//   ref: main comptime_var_type.zig:25:18 (+3 std frames)
// comptime_var_type.zig:9:11: error[comptime-var-escape]: sentinel contains reference to comptime var
//   | _ = [:&a]*u8;
//   note comptime_var_type.zig:9:11: 'sentinel' points to a comptime var, which is not available after the analysis that declares it
//   ref: main comptime_var_type.zig:26:18 (+3 std frames)
// comptime_var_type.zig:13:35: error[comptime-var-escape]: sentinel contains reference to comptime var
//   | _ = @Pointer(.many, .{}, *u8, &a);
//   note comptime_var_type.zig:13:35: 'sentinel' points to a comptime var, which is not available after the analysis that declares it
//   ref: main comptime_var_type.zig:27:20 (+3 std frames)
// comptime_var_type.zig:17:33: error[comptime-var-escape]: field default value contains reference to comptime var
//   | _ = struct { comptime *u8 = &a };
//   note comptime_var_type.zig:17:33: '0' points to a comptime var, which is not available after the analysis that declares it
//   ref: main comptime_var_type.zig:28:17 (+3 std frames)
// comptime_var_type.zig:21:50: error[comptime-var-escape]: field default value contains reference to comptime var
//   | _ = @Struct(.auto, null, &.{"foo"}, &.{*u8}, &.{.{ .default_value_ptr = @ptrCast(&&a) }});
//   note comptime_var_type.zig:21:50: 'foo' points to a comptime var, which is not available after the analysis that declares it
//   ref: main comptime_var_type.zig:29:19 (+3 std frames)
// 5 errors
