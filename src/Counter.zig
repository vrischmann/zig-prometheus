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

pub fn get(self: *const Self) u64 {
    return self.value.load(.SeqCst);
}

pub fn set(self: *Self, value: anytype) void {
    if (!comptime std.meta.trait.isNumber(@TypeOf(value))) {
        @compileError("can't set a non-number");
    }

    _ = self.value.store(@intCast(u64, value), .SeqCst);
}

pub fn writePrometheus(self: *const Self, writer: anytype, prefix: []const u8) !void {
    const value = self.get();
    try writer.print("{s} {d}", .{ prefix, value });
}

test "inc/add/dec/set/get" {
    var counter = @This(){};

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

test "writePrometheus" {
    var counter = @This(){};
    counter.set(340);

    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try counter.writePrometheus(buffer.writer(), "mycounter");

    try testing.expectEqualStrings("mycounter 340", buffer.items);
}