const std = @import("std");
const fmt = std.fmt;
const hash_map = std.hash_map;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;

const Metric = @import("metric.zig").Metric;
pub const Counter = @import("Counter.zig");
pub const Gauge = @import("Gauge.zig").Gauge;
pub const Histogram = @import("Histogram.zig").Histogram;
pub const GaugeCallFnType = @import("Gauge.zig").GaugeCallFnType;

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

        root_allocator: mem.Allocator,

        arena_state: heap.ArenaAllocator,

        mutex: std.Thread.Mutex,
        metrics: MetricMap,

        pub fn create(allocator: mem.Allocator) !*Self {
            const self = try allocator.create(Self);

            self.* = .{
                .root_allocator = allocator,
                .arena_state = heap.ArenaAllocator.init(allocator),
                .mutex = .{},
                .metrics = MetricMap{},
            };

            return self;
        }

        pub fn destroy(self: *Self) void {
            self.arena_state.deinit();
            self.root_allocator.destroy(self);
        }

        fn nbMetrics(self: *const Self) usize {
            return self.metrics.count();
        }

        pub fn getOrCreateCounter(self: *Self, name: []const u8) GetMetricError!*Counter {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            var allocator = self.arena_state.allocator();

            const duped_name = try allocator.dupe(u8, name);

            self.mutex.lock();
            defer self.mutex.unlock();

            const gop = try self.metrics.getOrPut(allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try Counter.init(allocator);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(Counter, "metric", gop.value_ptr.*);
        }

        pub fn getOrCreateHistogram(self: *Self, name: []const u8) GetMetricError!*Histogram {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            var allocator = self.arena_state.allocator();

            const duped_name = try allocator.dupe(u8, name);

            self.mutex.lock();
            defer self.mutex.unlock();

            const gop = try self.metrics.getOrPut(allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try Histogram.init(allocator);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(Histogram, "metric", gop.value_ptr.*);
        }

        pub fn getOrCreateGauge(
            self: *Self,
            name: []const u8,
            state: anytype,
            callFn: GaugeCallFnType(@TypeOf(state), f64),
        ) GetMetricError!*Gauge(@TypeOf(state), f64) {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            var allocator = self.arena_state.allocator();

            const duped_name = try allocator.dupe(u8, name);

            self.mutex.lock();
            defer self.mutex.unlock();

            const gop = try self.metrics.getOrPut(allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try Gauge(@TypeOf(state), f64).init(allocator, callFn, state);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(Gauge(@TypeOf(state), f64), "metric", gop.value_ptr.*);
        }

        pub fn getOrCreateGaugeInt(
            self: *Self,
            name: []const u8,
            state: anytype,
            callFn: GaugeCallFnType(@TypeOf(state), u64),
        ) GetMetricError!*Gauge(@TypeOf(state), u64) {
            if (self.nbMetrics() >= options.max_metrics) return error.TooManyMetrics;
            if (name.len > options.max_name_len) return error.NameTooLong;

            var allocator = self.arena_state.allocator();

            const duped_name = try allocator.dupe(u8, name);

            self.mutex.lock();
            defer self.mutex.unlock();

            const gop = try self.metrics.getOrPut(allocator, duped_name);
            if (!gop.found_existing) {
                var real_metric = try Gauge(@TypeOf(state), u64).init(allocator, callFn, state);
                gop.value_ptr.* = &real_metric.metric;
            }

            return @fieldParentPtr(Gauge(@TypeOf(state), u64), "metric", gop.value_ptr.*);
        }

        pub fn write(self: *Self, allocator: mem.Allocator, writer: anytype) !void {
            var arena_state = heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            self.mutex.lock();
            defer self.mutex.unlock();

            try writeMetrics(arena_state.allocator(), self.metrics, writer);
        }

        fn writeMetrics(allocator: mem.Allocator, map: MetricMap, writer: anytype) !void {
            // Get the keys, sorted
            const keys = blk: {
                var key_list = try std.ArrayList([]const u8).initCapacity(allocator, map.count());

                var key_iter = map.keyIterator();
                while (key_iter.next()) |key| {
                    key_list.appendAssumeCapacity(key.*);
                }

                break :blk key_list.items;
            };
            defer allocator.free(keys);

            std.mem.sort([]const u8, keys, {}, stringLessThan);

            // Write each metric in key order
            for (keys) |key| {
                var metric = map.get(key) orelse unreachable;
                try metric.write(allocator, writer, key);
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

test "registry write" {
    const TestCase = struct {
        counter_name: []const u8,
        gauge_name: []const u8,
        histogram_name: []const u8,
        exp: []const u8,
    };

    const exp1 =
        \\http_conn_pool_size 4.000000
        \\http_request_size_bucket{vmrange="1.292e+02...1.468e+02"} 1
        \\http_request_size_bucket{vmrange="4.642e+02...5.275e+02"} 1
        \\http_request_size_bucket{vmrange="1.136e+03...1.292e+03"} 1
        \\http_request_size_sum 1870.360000
        \\http_request_size_count 3
        \\http_requests 2
        \\
    ;

    const exp2 =
        \\http_conn_pool_size{route="/api/v2/users"} 4.000000
        \\http_request_size_bucket{route="/api/v2/users",vmrange="1.292e+02...1.468e+02"} 1
        \\http_request_size_bucket{route="/api/v2/users",vmrange="4.642e+02...5.275e+02"} 1
        \\http_request_size_bucket{route="/api/v2/users",vmrange="1.136e+03...1.292e+03"} 1
        \\http_request_size_sum{route="/api/v2/users"} 1870.360000
        \\http_request_size_count{route="/api/v2/users"} 3
        \\http_requests{route="/api/v2/users"} 2
        \\
    ;

    const test_cases = &[_]TestCase{
        .{
            .counter_name = "http_requests",
            .gauge_name = "http_conn_pool_size",
            .histogram_name = "http_request_size",
            .exp = exp1,
        },
        .{
            .counter_name = "http_requests{route=\"/api/v2/users\"}",
            .gauge_name = "http_conn_pool_size{route=\"/api/v2/users\"}",
            .histogram_name = "http_request_size{route=\"/api/v2/users\"}",
            .exp = exp2,
        },
    };

    inline for (test_cases) |tc| {
        var registry = try Registry(.{}).create(testing.allocator);
        defer registry.destroy();

        // Add some counters
        {
            var counter = try registry.getOrCreateCounter(tc.counter_name);
            counter.set(2);
        }

        // Add some gauges
        {
            _ = try registry.getOrCreateGauge(
                tc.gauge_name,
                @as(f64, 4.0),
                struct {
                    fn get(s: *f64) f64 {
                        return s.*;
                    }
                }.get,
            );
        }

        // Add an histogram
        {
            var histogram = try registry.getOrCreateHistogram(tc.histogram_name);

            histogram.update(500.12);
            histogram.update(1230.240);
            histogram.update(140);
        }

        // Write to a buffer
        {
            var buffer = std.ArrayList(u8).init(testing.allocator);
            defer buffer.deinit();

            try registry.write(testing.allocator, buffer.writer());

            try testing.expectEqualStrings(tc.exp, buffer.items);
        }

        // Write to  a file
        {
            const filename = "prometheus_metrics.txt";
            var file = try std.fs.cwd().createFile(filename, .{ .read = true });
            defer {
                file.close();
                std.fs.cwd().deleteFile(filename) catch {};
            }

            try registry.write(testing.allocator, file.writer());

            try file.seekTo(0);
            const file_data = try file.readToEndAlloc(testing.allocator, std.math.maxInt(usize));
            defer testing.allocator.free(file_data);

            try testing.expectEqualStrings(tc.exp, file_data);
        }
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

test {
    testing.refAllDecls(@This());
}
