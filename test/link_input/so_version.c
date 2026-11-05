/* A C object's export, versioned by so_version.map's wildcard, which
 * reaches a function the script makes local through a data pointer: the
 * loader must not bind it to another module (a RELATIVE record, not a
 * symbolic one). */
int c_local_fn(void) { return 4; }
int (*const c_local_ptr)(void) = c_local_fn;
int ver_c_one(void) { return c_local_ptr() - 1; }
