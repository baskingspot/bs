//! `--force_undefined keep_me` keeps this export, and `--force_undefined
//! fu_from_archive` pulls the archive member that defines that name
//! (force_undefined.c), whose constructor reports both.

export fn keep_me() callconv(.c) u32 {
    return 42;
}

pub fn main() void {}
