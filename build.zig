const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-prometheus", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    var example = b.addExecutable("example", "example/main.zig");
    example.addPackagePath("prometheus", "src/main.zig");
    example.setBuildMode(mode);
    example.install();

    const run_example_cmd = example.run();
    run_example_cmd.step.dependOn(b.getInstallStep());

    const run_example_step = b.step("run-example", "Run the example");
    run_example_step.dependOn(&run_example_cmd.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
