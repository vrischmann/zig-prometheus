const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const Metric = struct {
    pub const Error = error{
        OutOfMemory,
    } || std.os.WriteError;

    pub const Result = union(enum) {
        const Self = @This();

        counter: u64,
        gauge: f64,

        pub fn deinit(self: *const Self, allocator: *mem.Allocator) void {
            _ = allocator;
            switch (self) {
                else => {},
            }
        }
    };

    getResultFn: fn (self: *Metric, allocator: *mem.Allocator) Error!Result,

    pub fn write(self: *Metric, allocator: *mem.Allocator, writer: anytype, prefix: []const u8) Error!void {
        const result = try self.getResultFn(self, allocator);
        defer result.deinit(allocator);

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
