const std = @import("std");
const mem = std.mem;
const testing = std.testing;

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

test "counter" {
    var counter = @This(){};

    try testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    try testing.expectEqual(@as(u64, 1), counter.get());

    counter.add(200);
    try testing.expectEqual(@as(u64, 201), counter.get());

    counter.dec();
    try testing.expectEqual(@as(u64, 200), counter.get());
}
