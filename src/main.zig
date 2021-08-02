const std = @import("std");
const fmt = std.fmt;
const hash_map = std.hash_map;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;

const metrics = @import("metrics.zig");
pub const Counter = metrics.Counter;
pub const Metric = metrics.Metric;

pub const GetMetricError = error{
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

        const MetricMap = hash_map.StringHashMapUnmanaged(*Metric);

        root_allocator: *mem.Allocator,

        arena: heap.ArenaAllocator,
        allocator: *mem.Allocator,

        mutex: std.Thread.Mutex,
        metrics: MetricMap,

        pub fn create(allocator: *mem.Allocator) !*Self {
            const self = try allocator.create(Self);

            self.* = .{
                .root_allocator = allocator,
                .arena = heap.ArenaAllocator.init(allocator),
                .allocator = &self.arena.allocator,
                .mutex = .{},
                .metrics = MetricMap{},
            };

            return self;
        }

        pub fn destroy(self: *Self) void {
            self.arena.deinit();
            self.root_allocator.destroy(self);
        }

        fn nbMetrics(self: *const Self) usize {
            return self.metrics.count();
        }

        pub fn getOrCreate(self: *Self, comptime MetricType: type, name: []const u8) GetMetricError!*MetricType {
            if (MetricType != Counter and MetricType != Gauge) {
                @compileError("invalid MetricType " ++ @typeName(MetricType));
            }

            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            const held = self.mutex.acquire();
            defer held.release();

            const duped_name = try self.allocator.dupe(u8, name);

            var gop = try self.metrics.getOrPut(self.allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try MetricType.init(self.allocator);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(MetricType, "metric", gop.value_ptr.*);
        }

        pub fn writePrometheus(self: *Self, allocator: *mem.Allocator, writer: anytype) !void {
            var arena = heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            try writePrometheusMetrics(&arena.allocator, self.metrics, writer);
        }

        fn writePrometheusMetrics(allocator: *mem.Allocator, map: MetricMap, writer: anytype) !void {
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
                var metric = map.get(key) orelse unreachable;
                try metric.write(writer, key);
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
        var counter = try registry.getOrCreate(Counter, name);
        counter.inc();
    }

    var counter = try registry.getOrCreate(Counter, name);
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

        var counter = try registry.getOrCreate(Counter, name);
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
        try testing.expectError(error.NameTooLong, registry.getOrCreate(Counter, "hello"));
        _ = try registry.getOrCreate(Counter, "foo");
    }

    {
        try testing.expectError(error.TooManyMetrics, registry.getOrCreate(Counter, "bar"));
    }
}

test "" {
    testing.refAllDecls(@This());
}
