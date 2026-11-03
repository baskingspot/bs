//! The n-body simulation: f64 arithmetic on small structs passed by value.
const std = @import("std");

/// Exported and mutable, so no compiler treats the problem size as known.
export var scale: usize = 1;

const Vec = struct {
    x: f64,
    y: f64,
    z: f64,
    fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    fn scale(a: Vec, s: f64) Vec {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    fn dot(a: Vec, b: Vec) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
};

const Body = struct { pos: Vec, vel: Vec, mass: f64 };

const solar_mass = 4.0 * std.math.pi * std.math.pi;
const days_per_year = 365.24;

fn energy(bodies: []const Body) f64 {
    var e: f64 = 0;
    for (bodies, 0..) |b, i| {
        e += 0.5 * b.mass * b.vel.dot(b.vel);
        for (bodies[i + 1 ..]) |c| {
            const d = b.pos.sub(c.pos);
            e -= b.mass * c.mass / @sqrt(d.dot(d));
        }
    }
    return e;
}

fn advance(bodies: []Body, dt: f64) void {
    for (bodies, 0..) |*b, i| {
        for (bodies[i + 1 ..]) |*c| {
            const d = b.pos.sub(c.pos);
            const d2 = d.dot(d);
            const mag = dt / (d2 * @sqrt(d2));
            b.vel = b.vel.sub(d.scale(c.mass * mag));
            c.vel = c.vel.add(d.scale(b.mass * mag));
        }
    }
    for (bodies) |*b| b.pos = b.pos.add(b.vel.scale(dt));
}

pub fn main() void {
    var bodies = [_]Body{
        .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .vel = .{ .x = 0, .y = 0, .z = 0 }, .mass = solar_mass },
        .{ .pos = .{ .x = 4.84143144246472090e+00, .y = -1.16032004402742839e+00, .z = -1.03622044471123109e-01 }, .vel = .{ .x = 1.66007664274403694e-03 * days_per_year, .y = 7.69901118419740425e-03 * days_per_year, .z = -6.90460016972063023e-05 * days_per_year }, .mass = 9.54791938424326609e-04 * solar_mass },
        .{ .pos = .{ .x = 8.34336671824457987e+00, .y = 4.12479856412430479e+00, .z = -4.03523417114321381e-01 }, .vel = .{ .x = -2.76742510726862411e-03 * days_per_year, .y = 4.99852801234917238e-03 * days_per_year, .z = 2.30417297573763929e-05 * days_per_year }, .mass = 2.85885980666130812e-04 * solar_mass },
        .{ .pos = .{ .x = 1.28943695621391310e+01, .y = -1.51111514016986312e+01, .z = -2.23307578892655734e-01 }, .vel = .{ .x = 2.96460137564761618e-03 * days_per_year, .y = 2.37847173959480950e-03 * days_per_year, .z = -2.96589568540237556e-05 * days_per_year }, .mass = 4.36624404335156298e-05 * solar_mass },
        .{ .pos = .{ .x = 1.53796971148509165e+01, .y = -2.59193146099879641e+01, .z = 1.79258772950371181e-01 }, .vel = .{ .x = 2.68067772490389322e-03 * days_per_year, .y = 1.62824170038242295e-03 * days_per_year, .z = -9.51592254519715870e-05 * days_per_year }, .mass = 5.15138902046611451e-05 * solar_mass },
    };
    var momentum: Vec = .{ .x = 0, .y = 0, .z = 0 };
    for (bodies) |b| momentum = momentum.add(b.vel.scale(b.mass));
    bodies[0].vel = momentum.scale(-1.0 / solar_mass);
    const steps: usize = 500_000 * scale;
    const before = energy(&bodies);
    for (0..steps) |_| advance(&bodies, 0.01);
    std.debug.print("{d:.9} {d:.9}\n", .{ before, energy(&bodies) });
}
