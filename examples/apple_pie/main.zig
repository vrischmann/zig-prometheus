const std = @import("std");
const debug = std.debug;

const http = @import("apple_pie");
const prometheus = @import("prometheus");

const Registry = prometheus.Registry(.{});

const Context = struct {
    allocator: std.mem.Allocator,
    registry: *Registry,

    messages_total_counter: *prometheus.Counter,
};

const MessagesRouteArgs = struct {
    post: usize,
    message: []const u8,
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();

    // Initialize a registry
    var registry = try Registry.create(allocator);
    defer registry.destroy();

    var context = Context{
        .allocator = allocator,
        .registry = registry,
        .messages_total_counter = try registry.getOrCreateCounter("messages_total_counter"),
    };
    const builder = http.router.Builder(*Context);

    std.debug.print("listening on localhost:8080\n", .{});

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        &context,
        comptime http.router.Router(*Context, &.{
            builder.get("/", null, metrics),
            builder.get("/hello/:name", []const u8, hello),
            builder.get("/posts/:post/messages/:message", MessagesRouteArgs, messages),
        }),
    );
}

fn metrics(ctx: *Context, response: *http.Response, _: http.Request, captures: ?*const anyopaque) !void {
    debug.assert(captures == null);

    try ctx.registry.write(ctx.allocator, response.writer());
}

fn hello(ctx: *Context, _: *http.Response, _: http.Request, captures: ?*const anyopaque) !void {
    debug.assert(captures != null);

    const name_ptr = @ptrCast(
        *const []const u8,
        @alignCast(@alignOf(*const []const u8), captures),
    );
    const name = name_ptr.*;

    var counter_name = try std.fmt.allocPrint(ctx.allocator, "hello_total{{name=\"{s}\"}}", .{name});
    defer ctx.allocator.free(counter_name);

    var counter = try ctx.registry.getOrCreateCounter(counter_name);
    counter.inc();
}

fn messages(ctx: *Context, _: *http.Response, _: http.Request, captures: ?*const anyopaque) !void {
    debug.assert(captures != null);

    const args_ptr = @ptrCast(
        *const MessagesRouteArgs,
        @alignCast(@alignOf(*const MessagesRouteArgs), captures),
    );
    const args = args_ptr.*;

    std.debug.print("args: {s}\n", .{args});

    ctx.messages_total_counter.inc();
}
