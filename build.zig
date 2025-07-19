const builtin = @import("builtin");
const std = @import("std");

const zig_version = builtin.zig_version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "znvr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/znvr.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Assuming this is a bug for now, if it stays like this, make it a proper
    // semver check.
    const manually_link_winsock = target.result.os.tag == .windows and
        zig_version.major == 0 and zig_version.minor == 15;
    if (manually_link_winsock) {
        exe.linkSystemLibrary("ws2_32");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run znvr");
    run_step.dependOn(&run_cmd.step);
}
