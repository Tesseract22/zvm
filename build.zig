const std = @import("std");
const fatal = std.process.fatal;

pub fn get_git_commit(b: *std.Build) []const u8 {
    const io = b.graph.io;
    var run_git = std.process.spawn(io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .stdout = .pipe,
    }) catch |e| fatal("cannot spawn git: {}", .{ e });
    var buf: [64]u8 = undefined;
    var reader = run_git.stdout.?.reader(io, &buf);
    const git_commit = reader.interface.allocRemaining(b.allocator, .unlimited) catch unreachable;
    switch (run_git.wait(io) catch unreachable) {
        .exited => |code| if (code != 0) fatal("command `git` returns non-zero exit code: {}", .{code}),
        else => |any| fatal("command `git` terminated unexpectedly: {}", .{any}),
    }

    return git_commit;
}

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{});
    const opt = b.standardOptimizeOption(.{});

    // const git_commit = b.option([]conts u8, "commit", "git commit") orelse "";
    const options = b.addOptions();
    const git_commit = get_git_commit(b);
    options.addOption([]const u8, "commit", git_commit);

    const zvm_mod = b.addModule("zvm", .{
        .optimize = opt,
        .target = target,
        .root_source_file = b.path("src/main.zig"),
        .link_libc = true,
    });
    zvm_mod.addOptions("build", options);
    const zvm = b.addExecutable(.{
        .name = "zvm",
        .root_module = zvm_mod,
    });

    b.installArtifact(zvm);
}
