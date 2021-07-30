const std = @import("std");
const fmt = std.fmt;
const hash_map = std.hash_map;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;

pub const Counter = @import("Counter.zig");

pub const GetCounterError = error{
    // Returned when trying to add a metric to an already full registry.
    TooManyMetrics,
    // Returned when the name of name is bigger than the configured max_name_len.
    NameTooLong,

    OutOfMemory,
};

const RegistryOptions = struct {
    max_metrics: comptime_int = 8192,
    max_name_len: comptime_int = 1024,
};

pub fn Registry(comptime options: RegistryOptions) type {
    return struct {
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

        fn nbMetrics(self: *const Self) usize {
            return self.counters.count();
        }

        pub fn getOrCreateCounter(self: *Self, name: []const u8) GetCounterError!*Counter {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            const held = self.mutex.acquire();
            defer held.release();

            const duped_name = try self.allocator.dupe(u8, name);

            var gop = try self.counters.getOrPut(self.allocator, duped_name);
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
}

fn stringLessThan(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    return mem.lessThan(u8, lhs, rhs);
}

test "registry getOrCreateCounter" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var registry = try Registry(.{}).create(&arena.allocator);
    defer registry.destroy();

    const name = try fmt.allocPrint(&arena.allocator, "http_requests{{status=\"{d}\"}}", .{500});

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var counter = try registry.getOrCreateCounter(name);
        counter.inc();
    }

    var counter = try registry.getOrCreateCounter(name);
    try testing.expectEqual(@as(u64, 10), counter.get());
}

test "registry writePrometheus" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var registry = try Registry(.{}).create(&arena.allocator);
    defer registry.destroy();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const name = try fmt.allocPrint(&arena.allocator, "http_requests_{d}", .{i});

        var counter = try registry.getOrCreateCounter(name);
        counter.set(i * 2);
    }

    const exp =
        \\http_requests_0 0
        \\http_requests_1 2
        \\http_requests_2 4
        \\
    ;

    // Write to a buffer
    {
        var buffer = std.ArrayList(u8).init(&arena.allocator);
        defer buffer.deinit();

        try registry.writePrometheus(&arena.allocator, buffer.writer());

        try testing.expectEqualStrings(exp, buffer.items);
    }

    // Write to  a file
    {
        const filename = "prometheus_metrics.txt";
        var file = try std.fs.cwd().createFile(filename, .{ .read = true });
        defer {
            file.close();
            std.fs.cwd().deleteFile(filename) catch {};
        }

        try registry.writePrometheus(&arena.allocator, file.writer());

        try file.seekTo(0);
        const file_data = try file.readToEndAlloc(&arena.allocator, std.math.maxInt(usize));

        try testing.expectEqualStrings(exp, file_data);
    }
}

test "registry options" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var registry = try Registry(.{ .max_metrics = 1, .max_name_len = 4 }).create(&arena.allocator);
    defer registry.destroy();

    {
        try testing.expectError(error.NameTooLong, registry.getOrCreateCounter("hello"));
        _ = try registry.getOrCreateCounter("foo");
    }

    {
        try testing.expectError(error.TooManyMetrics, registry.getOrCreateCounter("bar"));
    }
}

test "" {
    testing.refAllDecls(@This());
}
