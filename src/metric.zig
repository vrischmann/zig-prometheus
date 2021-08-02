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
