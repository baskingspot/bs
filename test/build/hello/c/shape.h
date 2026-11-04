#include <stdio.h>
#include "sides.h"
#define SHAPE_AREA (SHAPE_SIDES * SHAPE_SCALE)
struct shape { int sides; const char *name; };
static inline int shape_sides(struct shape s) { return s.sides; }
