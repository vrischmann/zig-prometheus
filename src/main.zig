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

pub const GetCounterError = error{
    OutOfMemory,
};

pub const Registry = struct {
    const Self = @This();

    const CounterMap = MetricMap(Counter);

    allocator: *mem.Allocator,
    counters: CounterMap,

    pub fn init(self: *Self, allocator: *mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .counters = CounterMap.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.counters.deinit(self.allocator);
    }

    pub fn getOrCreateCounter(self: *Self, comptime name: []const u8) GetCounterError!*Counter {
        _ = self;
        _ = name;

        var gop = try self.counters.map.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    pub fn writePrometheus(writer: anytype) !void {
        _ = writer;
    }
};

var DefaultRegistry: Registry = undefined;

pub fn getCounter(comptime name: []const u8) GetCounterError!?*Counter {
    return DefaultRegistry.getCounter(name);
}

pub const GetCounterAllocError = error{};

pub fn getCounterAlloc(allocator: *mem.Allocator, name: []const u8, labels: anytype) GetCounterAllocError!?*Counter {
    _ = allocator;
    _ = name;
    _ = labels;
    return null;
}

test "registry init" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator);
    defer registry.deinit();

    const key = "http_requests{status=\"500\"}";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var counter = try registry.getOrCreateCounter(key);
        counter.inc();
    }

    var counter = try registry.getOrCreateCounter(key);
    try testing.expectEqual(@as(u64, 10), counter.get());
}

test "" {
    testing.refAllDecls(@This());
}
