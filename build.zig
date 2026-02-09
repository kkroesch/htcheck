const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // htcheck
    const htcheck = b.addExecutable(.{
        .name = "htcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(htcheck);

    // certcheck
    const certcheck = b.addExecutable(.{
        .name = "certcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/certcheck.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(certcheck);

    // Run targets
    const run_htcheck = b.addRunArtifact(htcheck);
    run_htcheck.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_htcheck.addArgs(args);
    b.step("run-htcheck", "Run htcheck").dependOn(&run_htcheck.step);

    const run_certcheck = b.addRunArtifact(certcheck);
    run_certcheck.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_certcheck.addArgs(args);
    b.step("run-certcheck", "Run certcheck").dependOn(&run_certcheck.step);

    // Tests for both
    const htcheck_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const certcheck_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/certcheck.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(htcheck_tests).step);
    test_step.dependOn(&b.addRunArtifact(certcheck_tests).step);
}
