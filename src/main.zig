const std = @import("std");
const mem = std.mem;
const testing = std.testing;

fn MetricMap(comptime Value: type) type {
    return struct {
        const Self = @This();

        const Key = []const u8;

        allocator: *mem.Allocator,
        map: std.hash_map.AutoHashMap(Key, Value),

        pub fn init(allocator: *mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
            };
        }
    };
}

pub const Registry = struct {
    counters: MetricMap(Counter),
};

const Counter = struct {};

pub fn getCounter(name: []const u8) GetCounterError!?*Counter {
    _ = name;
    return null;
}

pub fn getCounterAlloc(allocator: *mem.Allocator, name: []const u8, labels: anytype) GetCounterAllocError!?*Counter {
    _ = allocator;
    _ = name;
    _ = labels;
    return null;
}
