//! Declarations main.zig calls, in a module of the project.

pub const Color = enum {
    auto,

    /// Deprecated: use fromEnvironment instead
    pub fn get() Color {
        return .auto;
    }
};
