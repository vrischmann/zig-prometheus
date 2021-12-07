const std = @import("std");

const http = @import("apple_pie");
const prometheus = @import("prometheus");

const Registry = prometheus.Registry(.{});

const Context = struct {
    allocator: std.mem.Allocator,
    registry: *Registry,

    messages_total_counter: *prometheus.Counter,
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

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        &context,
        comptime http.router.Router(*Context, &.{
            http.router.get("/", metrics),
            http.router.get("/hello/:name", hello),
            http.router.get("/posts/:post/messages/:message", messages),
        }),
    );
}

fn metrics(ctx: *Context, response: *http.Response, request: http.Request) !void {
    _ = request;

    try ctx.registry.write(ctx.allocator, response.writer());
}

fn hello(ctx: *Context, resp: *http.Response, req: http.Request, name: []const u8) !void {
    _ = req;
    _ = resp;
    _ = name;

    var counter_name = try std.fmt.allocPrint(ctx.allocator, "hello_total{{name=\"{s}\"}}", .{name});
    defer ctx.allocator.free(counter_name);

    var counter = try ctx.registry.getOrCreateCounter(counter_name);
    counter.inc();
}

fn messages(ctx: *Context, resp: *http.Response, req: http.Request, args: struct {
    post: usize,
    message: []const u8,
}) !void {
    _ = req;
    _ = resp;
    _ = args;

    ctx.messages_total_counter.inc();
}
