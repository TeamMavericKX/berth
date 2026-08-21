const std = @import("std");

const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    "-DSQLITE_DQS=0",
    "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
    // Vendored C is audited upstream; Debug-mode UB instrumentation inside
    // sqlite3.c trips false panics on aarch64 (str_append pointer math).
    "-fno-sanitize=undefined",
};

fn linkSqlite(builder: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(builder.path("vendor/sqlite"));
    mod.addCSourceFile(.{
        .file = builder.path("vendor/sqlite/sqlite3.c"),
        .flags = &sqlite_flags,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "berth",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run berth");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const routes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/routes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_routes_tests = b.addRunArtifact(routes_tests);
    test_step.dependOn(&run_routes_tests.step);

    const db_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/db.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkSqlite(b, db_tests.root_module);
    const run_db_tests = b.addRunArtifact(db_tests);
    test_step.dependOn(&run_db_tests.step);

    const hosts_mod = b.createModule(.{
        .root_source_file = b.path("src/hostsync.zig"),
        .target = target,
        .optimize = optimize,
    });
    hosts_mod.link_libc = true;
    const hosts_tests = b.addTest(.{ .root_module = hosts_mod });
    const run_hosts_tests = b.addRunArtifact(hosts_tests);
    test_step.dependOn(&run_hosts_tests.step);

    const run_mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/run.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_run_tests = b.addRunArtifact(run_mod_tests);
    test_step.dependOn(&run_run_tests.step);

    const scanner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scanner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_scanner_tests = b.addRunArtifact(scanner_tests);
    test_step.dependOn(&run_scanner_tests.step);
}
