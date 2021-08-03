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

## Registry

The `Registry` is the entry point to obtain a metric type, as well as the type capable of serializing the metrics to a writer.

In an application it might be useful to have a default, global registry; in a library you probably should take one as a parameter.

### Creation

Here is how to get a registry:
```zig
var registry = try Registry(.{}).create(allocator);
defer registry.destroy();

...
```

Now you can get metric objects which we will describe later.

### Serializing the metrics

Once you have a registry you can serialize its metrics to a writer:
```zig
var registry = try Registry(.{}).create(allocator);
defer registry.destroy();

...

var file = try std.fs.cwd().createFile("metrics.txt", .{});
defer file.close();

try registry.write(allocator, file.writer());
```

The `write` method is thread safe.

## Counter

The `Counter` type is an atomic integer counter. You can get one like this:

```zig
var registry = try Registry(.{}).create(allocator);
defer registry.destroy();

var total_counter = try registry.getOrCreateCounter("http_requests_total");
var api_users_counter = try registry.getOrCreateCounter(
    \\http_requests{route="/api/v1/users"}
    ,
);
var api_articles_counter = try registry.getOrCreateCounter(
    \\http_requests{route="/api/v1/articles"}
    ,
);

total_counter.inc();
total_counter.dec();
total_counter.add(200);
total_counter.set(2400);
cosnt counter_value = total_counter.get();

```

Note that there's no helper to build the metric name with labels, you need to build the proper name yourself.

If you have dynamic labels you could write a helper function like this:
```zig

fn getHTTPRequestsCounter(allocator: *mem.Allocator, registry: *Registry, route: []const u8) !*prometheus.Counter {
    const name = try std.fmt.allocPrint(allocator, "http_requests{{route=\"{s}\"}}", .{route});
    return registry.getOrCreateCounter(name);
}

fn handler(route: []const u8) void {
    var counter = getHTTPRequestsCounter(router);
    counter.inc();
    ...
}
```

All methods on a `Counter` are thread safe.

## Gauge

The `Gauge` type represents a numerical value that is provided by a calling a user-supplied function.

TODO

## Histogram

TODO
