const std = @import("std");

const MESSAGE_SIZE = 8;
const QUEUE_SIZE = 4;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zipc",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption(comptime_int, "message_size", MESSAGE_SIZE);
    options.addOption(comptime_int, "queue_size", QUEUE_SIZE);
    lib.root_module.addOptions("build_options", options);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // const install_header = b.addInstallFile(lib.getEmittedH(), "include");
    // b.getInstallStep().dependOn(&install_header.step);

    // b.installArtifact(install_header);

    const exe = b.addExecutable(.{
        .name = "zipc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const c_test = b.addExecutable(.{
        .name = "c_test",
        .target = target,
        .optimize = optimize,
    });
    c_test.addCSourceFiles(.{
        .root = b.path("src/test"),
        .files = &.{ "test.c", "test_separate_threads.c", "test_single_thread_lock_step.c" },
    });
    const config_header = b.addConfigHeader(.{
        .include_path = "config.h",
        .style = .blank,
    }, .{
        .ZIPC_MESSAGE_SIZE = MESSAGE_SIZE,
        .ZIPC_QUEUE_SIZE = QUEUE_SIZE,
    });

    c_test.addConfigHeader(config_header);
    c_test.addIncludePath(b.path("include"));
    c_test.linkLibC();
    c_test.linkLibrary(lib);
    const run_c_tests = b.addRunArtifact(c_test);

    b.installArtifact(c_test);

    // Add server executable
    const server = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(server);

    // Add client executable
    const client = b.addExecutable(.{
        .name = "client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(client);

    // Add run steps for server and client
    const server_run_cmd = b.addRunArtifact(server);
    server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        server_run_cmd.addArgs(args);
    }
    const server_run_step = b.step("run-server", "Run the server");
    server_run_step.dependOn(&server_run_cmd.step);

    const client_run_cmd = b.addRunArtifact(client);
    client_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        client_run_cmd.addArgs(args);
    }
    const client_run_step = b.step("run-client", "Run the client");
    client_run_step.dependOn(&client_run_cmd.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    const run_c_tests_step = b.step("run-c-tests", "Run c tests");
    run_c_tests_step.dependOn(&run_c_tests.step);
}
