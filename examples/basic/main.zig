const std = @import("std");

const prometheus = @import("prometheus");

fn getRandomString(allocator: std.mem.Allocator, random: std.rand.Random, n: usize) ![]const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz";

    var items = try allocator.alloc(u8, n);
    for (items) |*item| {
        const random_pos = random.intRangeLessThan(usize, 0, alphabet.len);
        item.* = alphabet[random_pos];
    }

    return items;
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();

    var prng = std.rand.DefaultPrng.init(@bitCast(u64, std.time.milliTimestamp()));
    const random = prng.random();

    // Initialize a registry
    var registry = try prometheus.Registry(.{}).create(allocator);
    defer registry.destroy();

    // Get some counters
    {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const name = try std.fmt.allocPrint(allocator, "http_requests_total{{route=\"/{s}\"}}", .{
                try getRandomString(allocator, random, 20),
            });

            var counter = try registry.getOrCreateCounter(name);
            counter.add(random.intRangeAtMost(u64, 0, 450000));
        }
    }

    // Get some gauges sharing the same state.
    {
        const State = struct {
            random: std.rand.Random,
        };
        var state = State{ .random = random };

        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const name = try std.fmt.allocPrint(allocator, "http_conn_pool_size{{name=\"{s}\"}}", .{
                try getRandomString(allocator, random, 5),
            });

            _ = try registry.getOrCreateGauge(
                name,
                &state,
                struct {
                    fn get(s: *State) f64 {
                        const n = s.random.intRangeAtMost(usize, 0, 2000);
                        const f = s.random.float(f64);
                        return f * @intToFloat(f64, n);
                    }
                }.get,
            );
        }
    }

    // Get a histogram
    {
        const name = try std.fmt.allocPrint(allocator, "http_requests_latency{{route=\"/{s}\"}}", .{
            try getRandomString(allocator, random, 20),
        });

        var histogram = try registry.getOrCreateHistogram(name);

        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const duration = random.intRangeAtMost(usize, 0, 10000);
            histogram.update(@intToFloat(f64, duration));
        }
    }

    // Finally serialize the metrics to stdout

    try registry.write(allocator, std.io.getStdOut().writer());
}
