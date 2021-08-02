const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Metric = @import("metric.zig").Metric;

const Self = @This();

metric: Metric,
value: std.atomic.Atomic(u64),

pub fn init(allocator: *mem.Allocator) !*Self {
    const self = try allocator.create(Self);

    self.* = .{
        .metric = Metric{
            .getResultFn = getResult,
        },
        .value = .{ .value = 0 },
    };

    return self;
}

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

pub fn get(self: *const Self) u64 {
    return self.value.load(.SeqCst);
}

pub fn set(self: *Self, value: anytype) void {
    if (!comptime std.meta.trait.isNumber(@TypeOf(value))) {
        @compileError("can't set a non-number");
    }

    _ = self.value.store(@intCast(u64, value), .SeqCst);
}

fn getResult(metric: *Metric) Metric.Error!Metric.Result {
    const self = @fieldParentPtr(Self, "metric", metric);
    return Metric.Result{ .counter = self.get() };
}

test "counter: inc/add/dec/set/get" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var counter = try Self.init(testing.allocator);
    defer testing.allocator.destroy(counter);

    try testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    try testing.expectEqual(@as(u64, 1), counter.get());

    counter.add(200);
    try testing.expectEqual(@as(u64, 201), counter.get());

    counter.dec();
    try testing.expectEqual(@as(u64, 200), counter.get());

    counter.set(43);
    try testing.expectEqual(@as(u64, 43), counter.get());
}

test "counter: concurrent" {
    var counter = try Self.init(testing.allocator);
    defer testing.allocator.destroy(counter);

    var threads: [4]std.Thread = undefined;
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(
            .{},
            struct {
                fn run(c: *Self) void {
                    var i: usize = 0;
                    while (i < 20) : (i += 1) {
                        c.inc();
                    }
                }
            }.run,
            .{counter},
        );
    }

    for (threads) |*thread| thread.join();

    try testing.expectEqual(@as(u64, 80), counter.get());
}

test "counter: writePrometheus" {
    var counter = try Self.init(testing.allocator);
    defer testing.allocator.destroy(counter);
    counter.set(340);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var metric = &counter.metric;
    try metric.write(buffer.writer(), "mycounter");

    try testing.expectEqualStrings("mycounter 340\n", buffer.items);
}
