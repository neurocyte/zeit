const std = @import("std");
const zeit = @import("zeit");

// https://www.benjoffe.com/fast-time-of-day
// Retain the original arithmetic as a baseline. Include a narrowed sequential
// control to distinguish integer-width gains from dependency-chain gains.
const Variant = enum { baseline, narrow, v1, v2, v2_64 };
const variants = std.enums.values(Variant);
const Hms = struct { hour: u32, minute: u32, second: u32 };

fn hms(comptime variant: Variant, seconds: i64) Hms {
    if (variant == .baseline) {
        var remaining = seconds;
        const hours = @divFloor(remaining, 3600);
        remaining -= hours * 3600;
        const minutes = @divFloor(remaining, 60);
        remaining -= minutes * 60;
        return .{ .hour = @intCast(hours), .minute = @intCast(minutes), .second = @intCast(remaining) };
    }
    const t: u32 = @intCast(seconds);
    switch (variant) {
        .baseline => unreachable,
        .narrow => {
            const hours = t / 3600;
            const remaining = t - hours * 3600;
            const minutes = remaining / 60;
            return .{ .hour = hours, .minute = minutes, .second = remaining - minutes * 60 };
        },
        .v1 => {
            const total_minutes = t / 60;
            const hours = t / 3600;
            return .{ .hour = hours, .minute = total_minutes - hours * 60, .second = t - total_minutes * 60 };
        },
        .v2 => {
            const hprod = @as(u64, t) * 1193047;
            const mlow = t *% 71582789;
            const hlow: u32 = @truncate(hprod);
            return .{
                .hour = @intCast(hprod >> 32),
                .minute = @intCast(@as(u64, hlow) * 60 >> 32),
                .second = @intCast(@as(u64, mlow) * 60 >> 32),
            };
        },
        .v2_64 => {
            const hprod = @as(u128, t) * (@as(u64, 1193047) << 32);
            const mlow = @as(u64, t) *% (@as(u64, 71582789) << 32);
            const hlow: u64 = @truncate(hprod);
            return .{
                .hour = @intCast(hprod >> 64),
                .minute = @intCast(@as(u128, hlow) * 60 >> 64),
                .second = @intCast(@as(u128, mlow) * 60 >> 64),
            };
        },
    }
}

// The same call boundary for each variant prevents vectorization and ensures
// that all three fields are produced. Timings include call/loop/checksum costs.
noinline fn scalar(comptime variant: Variant, seconds: i64) Hms {
    return hms(variant, seconds);
}

noinline fn calendar(comptime variant: Variant, instant: zeit.Instant) zeit.Time {
    if (variant == .v1) return instant.time();

    // Mirror Instant.time(), changing ONLY the H:M:S decomposition.
    const adjusted = instant.timezone.adjust(instant.unixTimestamp());
    const date = zeit.civilFromDays(zeit.daysSinceEpoch(adjusted.timestamp));
    const clock = hms(variant, @mod(adjusted.timestamp, 86400));
    var nanos = @mod(instant.timestamp, 1_000_000_000);
    const millis = @divFloor(nanos, 1_000_000);
    nanos -= millis * 1_000_000;
    const micros = @divFloor(nanos, 1000);
    nanos -= micros * 1000;
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(clock.hour),
        .minute = @intCast(clock.minute),
        .second = @intCast(clock.second),
        .millisecond = @intCast(millis),
        .microsecond = @intCast(micros),
        .nanosecond = @intCast(nanos),
        .offset = @intCast(adjusted.timestamp - instant.unixTimestamp()),
        .designation = adjusted.designation,
    };
}

test "all seconds within a day" {
    for (0..86400) |s| {
        const seconds: i64 = @intCast(s);
        const expected = Hms{
            .hour = @intCast(@divFloor(seconds, 3600)),
            .minute = @intCast(@mod(@divFloor(seconds, 60), 60)),
            .second = @intCast(@mod(seconds, 60)),
        };
        inline for (variants) |variant| try std.testing.expectEqualDeep(expected, hms(variant, seconds));
    }
}

test "full conversion agrees across negative epochs, fractions, offsets and DST" {
    const zones = [_]zeit.TimeZone{
        zeit.utc,
        .{ .fixed = .{ .name = "east", .offset = 19800, .is_dst = false } },
        .{ .fixed = .{ .name = "west", .offset = -28800, .is_dst = false } },
        .{ .posix = try zeit.timezone.Posix.parse("CST6CDT,M3.2.0,M11.1.0") },
    };
    const seconds = [_]i64{
        -2208988800, -86401,     -86400,     -86399,     -3601,      -61,        -60,   -1,
        0,           1,          59,         60,         3599,       3600,       86399, 86400,
        86401,
        // Chicago's 2024 spring-forward and fall-back boundaries.
              1710057599, 1710057600, 1730617199, 1730617200, 4102444800,
    };
    for (&zones) |*zone| {
        for (seconds) |s| {
            for ([_]i128{ -1, 0, 1, 999, 1000, 999999, 1000000, 123456789, 999999999 }) |fraction| {
                const instant = zeit.Instant{ .timestamp = @as(i128, s) * 1_000_000_000 + fraction, .timezone = zone };
                inline for (variants) |variant| try std.testing.expectEqualDeep(instant.time(), calendar(variant, instant));
            }
        }
        var prng = std.Random.DefaultPrng.init(0x7e17);
        for (0..10000) |_| {
            const instant = zeit.Instant{
                .timestamp = @as(i128, prng.random().intRangeAtMost(i64, -2208988800, 4102444800)) * 1_000_000_000 + prng.random().uintLessThan(u32, 1_000_000_000),
                .timezone = zone,
            };
            inline for (variants) |variant| try std.testing.expectEqualDeep(instant.time(), calendar(variant, instant));
        }
    }
}

const Scope = enum { hms_throughput, hms_latency, instant_utc, instant_dst };
const sample_count = 9;
const input_count = 4096;
const repetitions = 512;
const Inputs = struct {
    seconds: [input_count]u32,
    timestamps: [input_count]i128,
};

fn timeChecksum(t: zeit.Time) u64 {
    return @as(u32, @bitCast(t.year)) +% @as(u64, @backingInt(t.month)) +% t.day +%
        t.hour +% t.minute +% t.second +% t.millisecond +% t.microsecond +% t.nanosecond +%
        @as(u32, @bitCast(t.offset)) +% t.designation.len;
}

fn run(comptime variant: Variant, comptime scope: Scope, inputs: *const Inputs, zone: *const zeit.TimeZone, repeats: usize) u64 {
    var sums: [4]u64 = @splat(0);
    for (0..repeats) |_| {
        for (0..input_count) |i| {
            if (scope == .hms_throughput or scope == .hms_latency) {
                const seconds = if (scope == .hms_latency)
                    (inputs.seconds[i] ^ @as(u32, @truncate(sums[0]))) % 86400
                else
                    inputs.seconds[i];
                const t = scalar(variant, seconds);
                const checksum = @as(u64, t.hour) + t.minute + t.second;
                if (scope == .hms_latency) {
                    sums[0] = checksum;
                } else {
                    sums[i % 4] +%= checksum;
                }
            } else {
                const t = calendar(variant, .{ .timestamp = inputs.timestamps[i], .timezone = zone });
                sums[i % 4] +%= timeChecksum(t);
            }
        }
    }
    return sums[0] +% sums[1] +% sums[2] +% sums[3];
}

pub fn main(init: std.process.Init) !void {
    var inputs: Inputs = undefined;
    var prng = std.Random.DefaultPrng.init(0x7e17);
    for (&inputs.seconds, &inputs.timestamps) |*seconds, *timestamp| {
        seconds.* = prng.random().uintLessThan(u32, 86400);
        timestamp.* = @as(i128, prng.random().intRangeAtMost(i64, -2208988800, 4102444800)) * 1_000_000_000 + prng.random().uintLessThan(u32, 1_000_000_000);
    }
    var zones = [_]zeit.TimeZone{ zeit.utc, .{ .posix = try zeit.timezone.Posix.parse("CST6CDT,M3.2.0,M11.1.0") } };
    // Keep timezone dispatch runtime-dependent, as in normal library usage.
    std.mem.doNotOptimizeAway(&zones);
    std.debug.print("{d} samples, {d} conversions/sample; ns/op includes harness overhead, no baseline subtraction\n", .{ sample_count, input_count * repetitions });
    inline for (std.enums.values(Scope)) |scope| {
        const zone = &zones[if (scope == .instant_dst) 1 else 0];
        var timings: [variants.len][sample_count]f64 = undefined;
        var expected: ?u64 = null;
        inline for (variants) |variant| std.mem.doNotOptimizeAway(run(variant, scope, &inputs, zone, 16));
        for (0..sample_count) |sample| {
            // Rotate order between samples to reduce systematic thermal bias.
            for (0..variants.len) |index| {
                const selected = (index + sample) % variants.len;
                inline for (variants, 0..) |variant, v| {
                    if (selected == v) {
                        const start = std.Io.Clock.awake.now(init.io);
                        const checksum = run(variant, scope, &inputs, zone, repetitions);
                        std.mem.doNotOptimizeAway(checksum);
                        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
                        if (expected) |value| {
                            if (value != checksum) return error.ChecksumMismatch;
                        } else expected = checksum;
                        timings[v][sample] = @as(f64, @floatFromInt(elapsed)) / (input_count * repetitions);
                    }
                }
            }
        }
        for (&timings) |*samples| std.mem.sort(f64, samples, {}, std.sort.asc(f64));
        std.debug.print("\n{s}: median ns/op [min, max], relative to baseline\n", .{@tagName(scope)});
        inline for (variants, 0..) |variant, v| {
            const samples = timings[v];
            std.debug.print("  {s: <8} {d:.3} [{d:.3}, {d:.3}] {d:.3}x\n", .{
                @tagName(variant),                                        samples[sample_count / 2], samples[0], samples[sample_count - 1],
                samples[sample_count / 2] / timings[0][sample_count / 2],
            });
        }
    }
}
