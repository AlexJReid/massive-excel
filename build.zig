const std = @import("std");

pub fn build(b: *std.Build) void {
    // ------------------------------------------------------------------
    // Build options — configurable Massive endpoint + optional insecure TLS
    // for local mock-server testing.
    // ------------------------------------------------------------------
    const massive_host = b.option([]const u8, "massive_host", "Massive WebSocket host") orelse "delayed.massive.com";
    const massive_port = b.option(u16, "massive_port", "Massive WebSocket port") orelse 443;
    const massive_path = b.option([]const u8, "massive_path", "Massive WebSocket path (e.g. /stocks)") orelse "/stocks";
    const massive_insecure = b.option(bool, "massive_insecure", "Skip TLS cert verification (for localhost testing only)") orelse false;

    const user_options = b.addOptions();
    user_options.addOption([]const u8, "massive_host", massive_host);
    user_options.addOption(u16, "massive_port", massive_port);
    user_options.addOption([]const u8, "massive_path", massive_path);
    user_options.addOption(bool, "massive_insecure", massive_insecure);

    // ------------------------------------------------------------------
    // Windows XLL build (the production artifact)
    // ------------------------------------------------------------------
    const win_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const user_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = win_target,
        .optimize = optimize,
    });
    user_module.addOptions("massive_options", user_options);

    const xll_build = @import("xll");
    const xll = xll_build.buildXll(b, .{
        .name = "standalone",
        .user_module = user_module,
        .target = win_target,
        .optimize = optimize,
    });

    const install_xll = b.addInstallFile(xll.getEmittedBin(), "lib/standalone.xll");
    b.getInstallStep().dependOn(&install_xll.step);

    // ------------------------------------------------------------------
    // Native CLI — smoke-test the WS client + Massive protocol on
    // whatever host you're developing on (mac/linux/windows).
    // Entry: src/massive_cli.zig.
    // ------------------------------------------------------------------
    const native_target = b.standardTargetOptions(.{});
    const cli = b.addExecutable(.{
        .name = "massive-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/massive_cli.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    cli.root_module.addOptions("massive_options", user_options);
    const install_cli = b.addInstallArtifact(cli, .{});

    const cli_step = b.step("massive-cli", "Build the native CLI smoke-tester");
    cli_step.dependOn(&install_cli.step);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run-cli", "Build and run the native CLI: zig build run-cli -- T.AAPL T.MSFT");
    run_step.dependOn(&run_cli.step);
}
