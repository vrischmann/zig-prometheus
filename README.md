# zig-prometheus

This is a [Zig](https://ziglang.org/) library to add [Prometheus](https://prometheus.io/docs/concepts/data_model/)-inspired metrics to a library or application.

"Inspired" because it is not strictly compatible with Prometheus, the `Histogram` type is tailored for [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics).
See [this blog post](https://valyala.medium.com/improving-histogram-usability-for-prometheus-and-grafana-bc7e5df0e350) from the creator of `VictoriaMetrics` for details.

# Requirements

[Zig master](https://ziglang.org/download/) is the only required dependency.

# Introduction

This library only provides the following types:
* A `Registry` holding a number of metrics
* A `Counter` metric type
* A `Gauge` metric type
* A `Histogram` metric type

# Examples

If you want a quick overview of how to use this library check the [basic example program](examples/basic/main.zig). It showcases everything.

# Reference

## Registry

The `Registry` is the entry point to obtain a metric type, as well as the type capable of serializing the metrics to a writer.

In an application it might be useful to have a default, global registry; in a library you probably should take one as a parameter.

### Creation

Here is how to get a registry:
```zig
var registry = try prometheus.Registry(.{}).create(allocator);
defer registry.destroy();
...
```

You can also configure some options for the registry:
```zig
var registry = try prometheus.Registry(.{ .max_metrics = 40, .max_name_len = 300 }).create(allocator);
defer registry.destroy();
...
```

If you want to store the registry in a variable you probably want to do something like this:
```zig
const Registry = prometheus.Registry(.{ .max_metrics = 40, .max_name_len = 300 });
var registry = Registry.create(allocator);
defer registry.destroy();
...
```

Now you can get metric objects which we will describe later.

### Serializing the metrics

Once you have a registry you can serialize its metrics to a writer:
```zig
var registry = try prometheus.Registry(.{}).create(allocator);
defer registry.destroy();

...

var file = try std.fs.cwd().createFile("metrics.txt", .{});
defer file.close();

try registry.write(allocator, file.writer());
```

The `write` method is thread safe.

## Counter

The `Counter` type is an atomic integer counter.

Here is an example of how to use a counter:

```zig
var registry = try prometheus.Registry(.{}).create(allocator);
defer registry.destroy();

var total_counter = try registry.getOrCreateCounter("http_requests_total");
var api_users_counter = try registry.getOrCreateCounter(
    \\http_requests{route="/api/v1/users"}
);
var api_articles_counter = try registry.getOrCreateCounter(
    \\http_requests{route="/api/v1/articles"}
);

total_counter.inc();
total_counter.dec();
total_counter.add(200);
total_counter.set(2400);
const counter_value = total_counter.get();
```

All methods on a `Counter` are thread safe.

## Gauge

The `Gauge` type represents a numerical value that is provided by calling a user-supplied function.

A `Gauge` is created with a _state_ and a _function_ which is given that state every time it is called.

For example, you can imagine a gauge returning the number of connections in a connection pool, the amount of memory allocated, etc.
Basically anytime the value is instantly queryable it could be a gauge.

Of course, nothing stops you from using a counter to simulate a gauge and calling `set` on it; it's up to you.

Here is an example gauge:
```zig
var registry = try prometheus.Registry(.{}).create(allocator);
defer registry.destroy();

const Conn = struct {};
const ConnPool = struct {
    conns: std.ArrayList(Conn),
};
var pool = ConnPool{ .conns = std.ArrayList.init(allocator) };

_ = try registry.getOrCreateGauge(
    "http_conn_pool_size",
    &pool,
    struct {
        fn get(p: *Pool) f64 {
            return @intToFloat(f64, p.conns.items.len);
        }
    }.get,
);
```

## Histogram

The `Histogram` type samples observations and counts them in automatically created buckets.

It can be used to observe things like request duration, request size, etc.

Here is a (contrived) example on how to use an histogram:
```zig
var registry = try prometheus.Registry(.{}).create(allocator);
defer registry.destroy();

var request_duration_histogram = try registry.getOrCreateHistogram("http_request_duration");

// Make 100 observations of some expensive operation.
var i: usize = 0;
while (i < 100) : (i += 1) {
    const start = std.time.milliTimestamp();

    var j: usize = 0;
    var sum: usize = 0;
    while (j < 2000000) : (j += 1) {
        sum *= j;
    }

    request_duration_histogram.update(@intToFloat(f64, std.time.milliTimestamp() - start));
}
```

## Using labels

If you're read the [Prometheus data model](https://prometheus.io/docs/concepts/data_model/#notation), you've seen that a metric can have labels.

Other Prometheus clients provide helpers for this, but not this library: you need to build the proper name yourself.

If you have static labels then it's easy, just write the label directly like this:
```zig
var http_requests_route_home = try registry.getOrCreateCounter(
    \\http_requests{route="/home"}
);
var http_requests_route_login = try registry.getOrCreateCounter(
    \\http_requests{route="/login"}
);
var http_requests_route_logout = try registry.getOrCreateCounter(
    \\http_requests{route="/logout"}
);
...
```

If you have dynamic labels you could write a helper function like this:
```zig
fn getHTTPRequestsCounter(
    allocator: *mem.Allocator,
    registry: *Registry,
    route: []const u8,
) !*prometheus.Counter {
    const name = try std.fmt.allocPrint(allocator, "http_requests{{route=\"{s}\"}}", .{
        route,
    });
    return try registry.getOrCreateCounter(name);
}

fn handler(route: []const u8) void {
    var counter = getHTTPRequestsCounter(allocator, registry, route);
    counter.inc();
}
```
