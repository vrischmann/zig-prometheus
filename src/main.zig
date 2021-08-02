const std = @import("std");
const fmt = std.fmt;
const hash_map = std.hash_map;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;

const metrics = @import("metrics.zig");

pub const Counter = metrics.Counter;
pub const Gauge = metrics.Gauge;
pub const GaugeCallFnType = metrics.GaugeCallFnType;
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

        pub fn getOrCreateCounter(self: *Self, name: []const u8) GetMetricError!*Counter {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            const duped_name = try self.allocator.dupe(u8, name);

            const held = self.mutex.acquire();
            defer held.release();

            var gop = try self.metrics.getOrPut(self.allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try Counter.init(self.allocator);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(Counter, "metric", gop.value_ptr.*);
        }

        pub fn getOrCreateGauge(
            self: *Self,
            name: []const u8,
            state: anytype,
            comptime callFn: GaugeCallFnType(@TypeOf(state)),
        ) GetMetricError!*Gauge(@TypeOf(state)) {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            const duped_name = try self.allocator.dupe(u8, name);

            const held = self.mutex.acquire();
            defer held.release();

            var gop = try self.metrics.getOrPut(self.allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try Gauge(@TypeOf(state)).init(self.allocator, callFn, state);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(Gauge(@TypeOf(state)), "metric", gop.value_ptr.*);
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
    var registry = try Registry(.{}).create(testing.allocator);
    defer registry.destroy();

    const name = try fmt.allocPrint(testing.allocator, "http_requests{{status=\"{d}\"}}", .{500});
    defer testing.allocator.free(name);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var counter = try registry.getOrCreateCounter(name);
        counter.inc();
    }

    var counter = try registry.getOrCreateCounter(name);
    try testing.expectEqual(@as(u64, 10), counter.get());
}

test "registry writePrometheus" {
    var registry = try Registry(.{}).create(testing.allocator);
    defer registry.destroy();

    // Add some counters
    {
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            const name = try fmt.allocPrint(testing.allocator, "http_requests_{d}", .{i});
            defer testing.allocator.free(name);

            var counter = try registry.getOrCreateCounter(name);
            counter.set(i * 2);
        }
    }

    // Add some gauges
    {
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            const name = try fmt.allocPrint(testing.allocator, "http_conn_pool_size_{d}", .{i});
            defer testing.allocator.free(name);

            var gauge = try registry.getOrCreateGauge(
                name,
                @as(f64, 0.0),
                struct {
                    fn get(s: *f64) f64 {
                        s.* += 2;
                        return s.*;
                    }
                }.get,
            );

            var j: usize = 0;
            while (j < i + 1) : (j += 1) {
                _ = gauge.get();
            }
        }
    }

    // Write to a buffer
    {
        var buffer = std.ArrayList(u8).init(testing.allocator);
        defer buffer.deinit();

        try registry.writePrometheus(testing.allocator, buffer.writer());

        const exp =
            \\http_conn_pool_size_0 4.000000
            \\http_conn_pool_size_1 6.000000
            \\http_requests_0 0
            \\http_requests_1 2
            \\
        ;

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

        try registry.writePrometheus(testing.allocator, file.writer());

        try file.seekTo(0);
        const file_data = try file.readToEndAlloc(testing.allocator, std.math.maxInt(usize));
        defer testing.allocator.free(file_data);

        const exp =
            \\http_conn_pool_size_0 6.000000
            \\http_conn_pool_size_1 8.000000
            \\http_requests_0 0
            \\http_requests_1 2
            \\
        ;

        try testing.expectEqualStrings(exp, file_data);
    }
}

test "registry options" {
    var registry = try Registry(.{ .max_metrics = 1, .max_name_len = 4 }).create(testing.allocator);
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
