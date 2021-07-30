const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
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
    NameTooLong,
    OutOfMemory,
};

const max_name_length = 1024;

pub const Registry = struct {
    const Self = @This();

    const CounterMap = MetricMap(Counter);

    arena: heap.ArenaAllocator,
    allocator: *mem.Allocator,

    counters: CounterMap,

    pub fn init(self: *Self, allocator: *mem.Allocator) !void {
        self.* = .{
            .allocator = undefined,
            .arena = heap.ArenaAllocator.init(allocator),
            .counters = CounterMap.init(),
        };
        self.allocator = &self.arena.allocator;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn getOrCreateCounter(self: *Self, comptime format: []const u8, values: anytype) GetCounterError!*Counter {
        if (format.len > max_name_length) return error.NameTooLong;

        const name = try fmt.allocPrint(self.allocator, format, values);

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

    const key = "http_requests{{status=\"{d}\"}}";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var counter = try registry.getOrCreateCounter(key, .{500});
        counter.inc();
    }

    var counter = try registry.getOrCreateCounter(key, .{500});
    try testing.expectEqual(@as(u64, 10), counter.get());
}

test "" {
    testing.refAllDecls(@This());
}
