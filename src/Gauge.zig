const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Metric = @import("metric.zig").Metric;

pub fn GaugeCallFnType(comptime StateType: type, comptime Return: type) type {
    const CallFnArgType = switch (@typeInfo(StateType)) {
        .pointer => StateType,
        .optional => |opt| opt.child,
        .void => void,
        else => *StateType,
    };

    return *const fn (state: CallFnArgType) Return;
}

pub fn Gauge(comptime StateType: type, comptime Return: type) type {
    const CallFnType = GaugeCallFnType(StateType, Return);

    return struct {
        const Self = @This();

        metric: Metric = .{
            .getResultFn = getResult,
        },
        callFn: CallFnType = undefined,
        state: StateType = undefined,

        pub fn init(allocator: mem.Allocator, callFn: CallFnType, state: StateType) !*Self {
            const self = try allocator.create(Self);

            self.* = .{};
            self.callFn = callFn;
            self.state = state;

            return self;
        }

        pub fn get(self: *Self) Return {
            const TypeInfo = @typeInfo(StateType);
            switch (TypeInfo) {
                .pointer, .void => {
                    return self.callFn(self.state);
                },
                .optional => {
                    if (self.state) |state| {
                        return self.callFn(state);
                    }
                    return 0;
                },
                else => {
                    return self.callFn(&self.state);
                },
            }
        }

        fn getResult(metric: *Metric, allocator: mem.Allocator) Metric.Error!Metric.Result {
            _ = allocator;

            const self: *Self = @fieldParentPtr("metric", metric);

            return switch (Return) {
                f64 => Metric.Result{ .gauge = self.get() },
                u64 => Metric.Result{ .gauge_int = self.get() },
                else => unreachable, // Gauge Return may only be 'f64' or 'u64'
            };
        }
    };
}

test "gauge: get" {
    const TestCase = struct {
        state_type: type,
        typ: type,
    };

    const testCases = [_]TestCase{
        .{
            .state_type = struct {
                value: f64,
            },
            .typ = f64,
        },
    };

    inline for (testCases) |tc| {
        const State = tc.state_type;
        const InnerType = tc.typ;

        var state = State{ .value = 20 };

        var gauge = try Gauge(*State, InnerType).init(
            testing.allocator,
            struct {
                fn get(s: *State) InnerType {
                    return s.value + 1;
                }
            }.get,
            &state,
        );
        defer testing.allocator.destroy(gauge);

        try testing.expectEqual(@as(InnerType, 21), gauge.get());
    }
}

test "gauge: optional state" {
    const State = struct {
        value: f64,
    };
    var state = State{ .value = 20.0 };

    var gauge = try Gauge(?*State, f64).init(
        testing.allocator,
        struct {
            fn get(s: *State) f64 {
                return s.value + 1.0;
            }
        }.get,
        &state,
    );
    defer testing.allocator.destroy(gauge);

    try testing.expectEqual(@as(f64, 21.0), gauge.get());
}

test "gauge: non-pointer state" {
    var gauge = try Gauge(f64, f64).init(
        testing.allocator,
        struct {
            fn get(s: *f64) f64 {
                s.* += 1.0;
                return s.*;
            }
        }.get,
        0.0,
    );
    defer testing.allocator.destroy(gauge);

    try testing.expectEqual(@as(f64, 1.0), gauge.get());
}

test "gauge: shared state" {
    const State = struct {
        mutex: std.Thread.Mutex = .{},
        items: std.ArrayList(usize) = std.ArrayList(usize).init(testing.allocator),
    };
    var shared_state = State{};
    defer shared_state.items.deinit();

    var gauge = try Gauge(*State, f64).init(
        testing.allocator,
        struct {
            fn get(state: *State) f64 {
                return @floatFromInt(state.items.items.len);
            }
        }.get,
        &shared_state,
    );
    defer testing.allocator.destroy(gauge);

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, thread_index| {
        thread.* = try std.Thread.spawn(
            .{},
            struct {
                fn run(thread_idx: usize, state: *State) !void {
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        state.mutex.lock();
                        defer state.mutex.unlock();
                        try state.items.append(thread_idx + i);
                    }
                }
            }.run,
            .{ thread_index, &shared_state },
        );
    }

    for (&threads) |*thread| thread.join();

    try testing.expectEqual(@as(usize, 16), @as(usize, @intFromFloat(gauge.get())));
}

test "gauge: write" {
    var gauge = try Gauge(usize, f64).init(
        testing.allocator,
        struct {
            fn get(state: *usize) f64 {
                state.* += 340;
                return @floatFromInt(state.*);
            }
        }.get,
        @as(usize, 0),
    );
    defer testing.allocator.destroy(gauge);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var metric = &gauge.metric;
    try metric.write(testing.allocator, buffer.writer(), "mygauge");

    try testing.expectEqualStrings("mygauge 340.000000\n", buffer.items);
}
