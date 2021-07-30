const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const Counter = @import("Counter.zig");

fn MetricMap(comptime Value: type) type {
    return struct {
        const Self = @This();

        const MapType = std.hash_map.StringHashMapUnmanaged(Value);

        map: MapType = .{},

        pub fn init() Self {
            return Self{};
        }

        pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
            self.map.deinit(allocator);
        }
    };
}

pub const Registry = struct {
    const Self = @This();

    const CounterMap = MetricMap(Counter);

    allocator: *mem.Allocator,
    counters: CounterMap,

    pub fn init(allocator: *mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .counters = CounterMap.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.counters.deinit(self.allocator);
    }
};

pub const GetCounterError = error{};

pub fn getCounter(name: []const u8) GetCounterError!?*Counter {
    _ = name;
    return null;
}

pub const GetCounterAllocError = error{};

pub fn getCounterAlloc(allocator: *mem.Allocator, name: []const u8, labels: anytype) GetCounterAllocError!?*Counter {
    _ = allocator;
    _ = name;
    _ = labels;
    return null;
}

test "registry init" {
    var registry = Registry.init(testing.allocator);
    defer registry.deinit();
}

test "" {
    testing.refAllDecls(@This());
}
