const std = @import("std");
const deps = @import("deps.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-prometheus", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const examples = &[_][]const u8{
        "apple_pie",
        "basic",
    };

    inline for (examples) |name| {
        var exe = b.addExecutable("example-" ++ name, "examples/" ++ name ++ "/main.zig");
        deps.addAllTo(exe);
        exe.setBuildMode(mode);
        exe.install();

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run-example-" ++ name, "Run the example " ++ name);
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
