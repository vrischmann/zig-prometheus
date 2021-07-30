const std = @import("std");
const mem = std.mem;
const testing = std.testing;

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

pub const Counter = struct {
    const Self = @This();

    value: std.atomic.Atomic(u64) = .{ .value = 0 },

    pub fn inc(self: *Self) void {
        _ = self.value.fetchAdd(1, .SeqCst);
    }

    pub fn dec(self: *Self) void {
        _ = self.value.fetchSub(1, .SeqCst);
    }

    pub fn add(self: *Self, value: anytype) void {
        if (!comptime std.meta.trait.isNumber(@TypeOf(value))) {
            @compileError("can't add a non-number");
        }

        _ = self.value.fetchAdd(@intCast(u64, value), .SeqCst);
    }

    pub fn get(self: *Self) u64 {
        return self.value.load(.SeqCst);
    }

    pub fn set(self: *Self, value: anytype) u64 {
        if (!comptime std.meta.trait.isNumber(@TypeOf(value))) {
            @compileError("can't set a non-number");
        }

        _ = self.value.store(@intCast(u64, value), .SeqCst);
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

test "counter" {
    var counter = Counter{};

    try testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    try testing.expectEqual(@as(u64, 1), counter.get());

    counter.add(200);
    try testing.expectEqual(@as(u64, 201), counter.get());

    counter.dec();
    try testing.expectEqual(@as(u64, 200), counter.get());
}

test "" {
    testing.refAllDecls(@This());
}
