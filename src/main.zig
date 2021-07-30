const std = @import("std");
const fmt = std.fmt;
const hash_map = std.hash_map;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;

pub const Counter = @import("Counter.zig");

pub const GetCounterError = error{
    NameTooLong,
    OutOfMemory,
};

const max_name_length = 1024;

pub const Registry = struct {
    const Self = @This();

    const CounterMap = hash_map.StringHashMapUnmanaged(Counter);

    allocator: *mem.Allocator,

    mutex: std.Thread.Mutex,
    counters: CounterMap,

    pub fn create(allocator: *mem.Allocator) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .allocator = allocator,
            .mutex = .{},
            .counters = CounterMap{},
        };

        return self;
    }

    pub fn destroy(self: *Self) void {
        self.counters.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getOrCreateCounter(self: *Self, comptime format: []const u8, values: anytype) GetCounterError!*Counter {
        const held = self.mutex.acquire();
        defer held.release();

        if (format.len > max_name_length) return error.NameTooLong;

        const name = try fmt.allocPrint(self.allocator, format, values);

        var gop = try self.counters.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    pub fn writePrometheus(self: *Self, allocator: *mem.Allocator, writer: anytype) !void {
        var arena = heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        try writePrometheusMetrics(&arena.allocator, CounterMap, self.counters, writer);
    }

    fn writePrometheusMetrics(allocator: *mem.Allocator, comptime MapType: type, map: MapType, writer: anytype) !void {
        // Get the keys, sorted
        const keys = blk: {
            var key_list = try std.ArrayList([]const u8).initCapacity(allocator, map.count());

            var key_iter = map.keyIterator();
            while (key_iter.next()) |key| {
                key_list.appendAssumeCapacity(key.*);
            }

            break :blk key_list.toOwnedSlice();
        };

        std.sort.sort([]const u8, keys, {}, stringLessThan);

        // Write each metric in key order
        for (keys) |key| {
            const value = map.get(key) orelse unreachable;

            try value.writePrometheus(writer, key);
        }
    }
};

fn stringLessThan(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    return mem.lessThan(u8, lhs, rhs);
}

test "registry getOrCreateCounter" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var registry = try Registry.create(&arena.allocator);
    defer registry.destroy();

    const key = "http_requests{{status=\"{d}\"}}";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var counter = try registry.getOrCreateCounter(key, .{500});
        counter.inc();
    }

    var counter = try registry.getOrCreateCounter(key, .{500});
    try testing.expectEqual(@as(u64, 10), counter.get());
}

test "registry writePrometheus" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var registry = try Registry.create(&arena.allocator);
    defer registry.destroy();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var counter = try registry.getOrCreateCounter("http_requests{d}", .{i});
        counter.set(i * 2);
    }

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try registry.writePrometheus(std.testing.allocator, buffer.writer());

    const exp =
        \\http_requests0 0
        \\http_requests1 2
        \\http_requests2 4
        \\
    ;

    try testing.expectEqualStrings(exp, buffer.items);
}

test "" {
    testing.refAllDecls(@This());
}
