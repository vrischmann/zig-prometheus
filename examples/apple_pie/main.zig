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
    post: []const u8,
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
            builder.get("/", metrics),
            builder.get("/hello/:name", hello),
            builder.get("/posts/:post/messages/:message", messages),
        }),
    );
}

fn metrics(ctx: *Context, response: *http.Response, _: http.Request) !void {
    try ctx.registry.write(ctx.allocator, response.writer());
}

fn hello(ctx: *Context, _: *http.Response, _: http.Request, name: []const u8) !void {
    var counter_name = try std.fmt.allocPrint(ctx.allocator, "hello_total{{name=\"{s}\"}}", .{name});
    defer ctx.allocator.free(counter_name);

    var counter = try ctx.registry.getOrCreateCounter(counter_name);
    counter.inc();
}

fn messages(ctx: *Context, _: *http.Response, _: http.Request, captures: MessagesRouteArgs) !void {
    std.debug.print("args: {}\n", .{captures});

    ctx.messages_total_counter.inc();
}
