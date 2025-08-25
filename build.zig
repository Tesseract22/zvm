const std = @import("std");

pub fn build(b: *std.Build) void {

    const target = b.resolveTargetQuery(.{});
    const opt = b.standardOptimizeOption(.{});
    
    const zvm_mod = b.addModule("zvm", .{
        .optimize = opt,
        .target = target,
        .root_source_file = b.path("src/main.zig"),
        .link_libc = true,
    });
    zvm_mod.linkSystemLibrary("curl", .{});
    const zvm = b.addExecutable(.{
        .name = "zvm",
        .root_module = zvm_mod,
    });

    b.installArtifact(zvm);
    const run_zvm = b.addRunArtifact(zvm);
    if (b.args) |args|
        run_zvm.addArgs(args);
    const run_step = b.step("run", "");
    run_step.dependOn(&run_zvm.step);

}
