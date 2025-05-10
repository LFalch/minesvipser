const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = if (optimize == .Debug) false else null;

    const spoon = b.dependency("spoon", .{
        .target = target,
        .optimize = optimize,
    });
    const spoon_mod = spoon.module("spoon");

    const exe = b.addExecutable(.{
        .name = "minesvipser",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    });
    exe.root_module.addImport("spoon", spoon_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    });
    exe_unit_tests.root_module.addImport("spoon", spoon_mod);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_unit_tests.step);
}
