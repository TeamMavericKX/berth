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

    // TLS termination needs a system OpenSSL; cross-compile targets and
    // CI matrix jobs build without it and get stubs that fail closed.
    const openssl = b.option(bool, "openssl", "Link system OpenSSL for TLS termination (M3)") orelse false;

    const opts = b.addOptions();
    opts.addOption(bool, "openssl", openssl);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", opts);
    linkSqlite(b, exe_mod);
    if (openssl) {
        exe_mod.linkSystemLibrary("ssl", .{});
        exe_mod.linkSystemLibrary("crypto", .{});
    }

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

    const dash_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dash.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const certs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/certs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    certs_tests.root_module.link_libc = true;
    const run_certs_tests = b.addRunArtifact(certs_tests);
    test_step.dependOn(&run_certs_tests.step);

    const tls_mod = b.createModule(.{
        .root_source_file = b.path("src/tls.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_mod.addOptions("build_options", opts);
    if (openssl) {
        tls_mod.link_libc = true;
        tls_mod.linkSystemLibrary("ssl", .{});
        tls_mod.linkSystemLibrary("crypto", .{});
    }
    const tls_tests = b.addTest(.{ .root_module = tls_mod });
    const run_tls_tests = b.addRunArtifact(tls_tests);
    test_step.dependOn(&run_tls_tests.step);

    const trust_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/trust.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_trust_tests = b.addRunArtifact(trust_tests);
    test_step.dependOn(&run_trust_tests.step);

    const clean_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clean.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_clean_tests = b.addRunArtifact(clean_tests);
    test_step.dependOn(&run_clean_tests.step);

    const worktree_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/worktree.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_worktree_tests = b.addRunArtifact(worktree_tests);
    test_step.dependOn(&run_worktree_tests.step);

    const inject_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inject.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_inject_tests = b.addRunArtifact(inject_tests);
    test_step.dependOn(&run_inject_tests.step);

    const tunnel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tunnel.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tunnel_tests = b.addRunArtifact(tunnel_tests);
    test_step.dependOn(&run_tunnel_tests.step);

    const containers_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/containers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    containers_tests.root_module.link_libc = true;
    const run_containers_tests = b.addRunArtifact(containers_tests);
    test_step.dependOn(&run_containers_tests.step);

    const kill_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kill.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kill_tests.root_module.link_libc = true;
    const run_kill_tests = b.addRunArtifact(kill_tests);
    test_step.dependOn(&run_kill_tests.step);

    linkSqlite(b, dash_tests.root_module);
    const run_dash_tests = b.addRunArtifact(dash_tests);
    test_step.dependOn(&run_dash_tests.step);

    const ports_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ports.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ports_tests = b.addRunArtifact(ports_tests);
    test_step.dependOn(&run_ports_tests.step);
}
