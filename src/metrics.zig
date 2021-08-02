const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const Metric = struct {
    pub const Error = error{
        OutOfMemory,
    } || std.os.WriteError;

    pub const Result = union(enum) {
        counter: u64,
        gauge: f64,
    };

    getResultFn: fn (self: *Metric) Error!Result,

    pub fn write(self: *Metric, writer: anytype, prefix: []const u8) Error!void {
        const result = try self.getResultFn(self);

        switch (result) {
            .counter => |v| {
                return try writer.print("{s} {d}\n", .{ prefix, v });
            },
            .gauge => |v| {
                return try writer.print("{s} {d:.6}\n", .{ prefix, v });
            },
        }
    }
};

pub const Counter = struct {
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
        const self = @fieldParentPtr(Counter, "metric", metric);
        return Metric.Result{ .counter = self.get() };
    }
};

test "counter: inc/add/dec/set/get" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var counter = try Counter.init(std.testing.allocator);
    defer std.testing.allocator.destroy(counter);

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
    var counter = try Counter.init(std.testing.allocator);
    defer std.testing.allocator.destroy(counter);

    var threads: [4]std.Thread = undefined;
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(
            .{},
            struct {
                fn run(c: *Counter) void {
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
    var counter = try Counter.init(std.testing.allocator);
    defer std.testing.allocator.destroy(counter);
    counter.set(340);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var metric = &counter.metric;
    try metric.write(buffer.writer(), "mycounter");

    try testing.expectEqualStrings("mycounter 340\n", buffer.items);
}

pub fn Gauge(comptime StateType: type) type {
    const StateTypeInfo = @typeInfo(StateType);

    const CallFnArgType = switch (StateTypeInfo) {
        .Pointer => StateType,
        .Optional => |opt| opt.child,
        else => *StateType,
    };

    const CallFnType = fn (comptime state: CallFnArgType) f64;

    return struct {
        const Self = @This();

        metric: Metric,
        callFn: CallFnType,
        state: StateType,

        pub fn init(comptime callFn: CallFnType, state: StateType) Self {
            return Self{
                .metric = Metric{
                    .getResultFn = getResult,
                },
                .callFn = callFn,
                .state = state,
            };
        }

        pub fn get(self: *Self) f64 {
            const TypeInfo = @typeInfo(StateType);
            switch (TypeInfo) {
                .Pointer => {
                    return self.callFn(self.state);
                },
                .Optional => {
                    if (self.state) |state| {
                        return self.callFn(state);
                    } else {
                        return 0.0;
                    }
                },
                else => {
                    return self.callFn(&self.state);
                },
            }
        }

        fn getResult(metric: *Metric) Metric.Error!Metric.Result {
            const self = @fieldParentPtr(Self, "metric", metric);
            return Metric.Result{ .gauge = self.get() };
        }
    };
}

test "gauge: get" {
    const State = struct {
        value: f64,
    };
    var state = State{ .value = 20.0 };

    var gauge = Gauge(*State).init(
        struct {
            fn get(s: *State) f64 {
                return s.value + 1.0;
            }
        }.get,
        &state,
    );

    try testing.expectEqual(@as(f64, 21.0), gauge.get());
}

test "gauge: optional state" {
    const State = struct {
        value: f64,
    };
    var state = State{ .value = 20.0 };

    var gauge = Gauge(?*State).init(
        struct {
            fn get(s: *State) f64 {
                return s.value + 1.0;
            }
        }.get,
        &state,
    );

    try testing.expectEqual(@as(f64, 21.0), gauge.get());
}

test "gauge: non-pointer state" {
    var gauge = Gauge(f64).init(
        struct {
            fn get(s: *f64) f64 {
                s.* += 1.0;
                return s.*;
            }
        }.get,
        0.0,
    );
    try testing.expectEqual(@as(f64, 1.0), gauge.get());
}

test "gauge: shared state" {
    const State = struct {
        mutex: std.Thread.Mutex = .{},
        items: std.ArrayList(usize) = std.ArrayList(usize).init(std.testing.allocator),
    };
    var shared_state = State{};
    defer shared_state.items.deinit();

    var gauge = Gauge(*State).init(
        struct {
            fn get(state: *State) f64 {
                return @intToFloat(f64, state.items.items.len);
            }
        }.get,
        &shared_state,
    );

    var threads: [4]std.Thread = undefined;
    for (threads) |*thread, thread_index| {
        thread.* = try std.Thread.spawn(
            .{},
            struct {
                fn run(thread_idx: usize, state: *State) !void {
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        const held = state.mutex.acquire();
                        defer held.release();
                        try state.items.append(thread_idx + i);
                    }
                }
            }.run,
            .{ thread_index, &shared_state },
        );
    }

    for (threads) |*thread| thread.join();

    try testing.expectEqual(@as(usize, 16), @floatToInt(usize, gauge.get()));
}
