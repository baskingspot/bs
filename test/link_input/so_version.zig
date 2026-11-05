// A shared library linked with a version script (so_version.map): its
// nodes version these exports and so_version.c's, and hide the rest.
export fn ver_old() c_int {
    return 1;
}
export fn ver_new() c_int {
    return ver_hidden() + 1;
}
export fn ver_hidden() c_int {
    return 1;
}
