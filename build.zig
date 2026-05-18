const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const semver = try incrementBuildNumber(b);

    const lib_mod = b.addModule("libchroma", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const target_result = target.result;
    const is_wasm = target_result.cpu.arch == .wasm32;

    const static_lib = addLibs(b, lib_mod, semver);
    if (!is_wasm) {
        addCli(b, lib_mod, target, optimize);
        addTests(b, lib_mod, target, optimize);
        addExamples(b, lib_mod, static_lib, target, optimize);
    }

    const nuke_step = b.step("nuke", "Remove all build artifacts and cache");
    nuke_step.dependOn(&b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache", "zig-out" }).step);
}

fn addLibs(b: *std.Build, lib_mod: *std.Build.Module, semver: std.SemanticVersion) *std.Build.Step.Compile {
    const target_result = lib_mod.resolved_target.?.result;
    const is_wasm = target_result.cpu.arch == .wasm32;

    const lib_step = b.step("lib", "Build only the library (static + dynamic or wasm32)");

    if (is_wasm) {
        const wasm_mod = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = lib_mod.resolved_target.?,
            .optimize = lib_mod.optimize.?,
            .link_libc = false,
        });
        const wasm_exe = b.addExecutable(.{
            .name = "chroma",
            .root_module = wasm_mod,
        });
        wasm_exe.entry = .disabled;
        const install = b.addInstallArtifact(wasm_exe, .{});
        lib_step.dependOn(&install.step);
        return wasm_exe;
    }

    const static_lib = b.addLibrary(.{
        .name = "chroma",
        .linkage = .static,
        .root_module = lib_mod,
        .version = semver,
    });
    const dynamic_lib = b.addLibrary(.{
        .name = "chroma",
        .linkage = .dynamic,
        .root_module = lib_mod,
        .version = semver,
    });
    const install_static = b.addInstallArtifact(static_lib, .{});
    const install_dynamic = b.addInstallArtifact(dynamic_lib, .{});
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    b.getInstallStep().dependOn(&install_static.step);
    b.getInstallStep().dependOn(&install_dynamic.step);
    b.getInstallStep().dependOn(&install_headers.step);
    lib_step.dependOn(&install_static.step);
    lib_step.dependOn(&install_dynamic.step);
    lib_step.dependOn(&install_headers.step);

    return static_lib;
}

fn addCli(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("libchroma", lib_mod);
    const exe = b.addExecutable(.{ .name = "chroma", .root_module = exe_mod });
    b.installArtifact(exe);

    const cli_step = b.step("cli", "Build only the CLI executable");
    cli_step.dependOn(&exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "Check if libchroma compiles");
    check_step.dependOn(&exe.step);
}

fn addTests(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/chroma.h"),
        .target = target,
        .optimize = optimize,
    });
    lib_tests.root_module.addImport("chroma_h", translate_c.createModule());
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("libchroma", lib_mod);
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const Scope = enum { lib, exe };
    const scope = b.option(Scope, "scope", "Test scope (leave blank for all)");
    const test_step = b.step("test", "Run tests (-Dscope=lib|exe)");
    if (scope == null or scope.? == .lib)
        test_step.dependOn(&run_lib_tests.step);
    if (scope == null or scope.? == .exe)
        test_step.dependOn(&run_exe_tests.step);
}

fn addExamples(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    static_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const examples_step = b.step("examples", "Build examples (installs to zig-out/bin/)");

    // C examples
    inline for (.{ "basic", "convert", "gamut_map" }) |name| {
        const c_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        c_mod.addCSourceFiles(.{ .files = &.{"examples/" ++ name ++ ".c"} });
        c_mod.addIncludePath(b.path("include"));
        c_mod.linkLibrary(static_lib);
        const exe = b.addExecutable(.{ .name = name, .root_module = c_mod });
        const install = b.addInstallArtifact(exe, .{ .dest_sub_path = "examples/" ++ name ++ "-c" });
        examples_step.dependOn(&install.step);
    }

    // Zig examples
    inline for (.{ "basic", "comptime", "palette" }) |name| {
        const zig_mod = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        zig_mod.addImport("libchroma", lib_mod);
        const exe = b.addExecutable(.{ .name = name, .root_module = zig_mod });
        const install = b.addInstallArtifact(exe, .{ .dest_sub_path = "examples/" ++ name ++ "-zig" });
        examples_step.dependOn(&install.step);
    }
}

fn incrementBuildNumber(b: *std.Build) !std.SemanticVersion {
    const alloc = b.allocator;
    const manifest = @embedFile("build.zig.zon");
    const range = try findVersion(manifest);
    const old_version = manifest[range.start..range.end];
    const new_version = try bumpVersion(alloc, old_version);
    const new_manifest = try std.mem.concat(alloc, u8, &.{ manifest[0..range.start], new_version, manifest[range.end..] });

    const io = b.graph.io;
    var file = try b.build_root.handle.openFile(io, "build.zig.zon", .{ .mode = .write_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(new_manifest);
    try w.interface.flush();

    return std.SemanticVersion.parse(new_version);
}

const field = "version";
fn findVersion(manifest: []const u8) !struct { start: usize, end: usize } {
    var i: usize = 0;

    while (i + field.len < manifest.len) : (i += 1) {
        if (!std.mem.eql(u8, manifest[i .. i + field.len], field)) continue;

        i += field.len;
        while (i < manifest.len and std.ascii.isWhitespace(manifest[i])) i += 1;
        if (i >= manifest.len or manifest[i] != '=') continue;
        i += 1;
        while (i < manifest.len and std.ascii.isWhitespace(manifest[i])) i += 1;
        if (i >= manifest.len or manifest[i] != '"') return error.MalformedVersion;

        const start = i + 1;
        i = start;
        while (i < manifest.len and manifest[i] != '"') i += 1;
        if (i >= manifest.len) return error.UnterminatedString;

        return .{ .start = start, .end = i };
    }

    return error.VersionNotFound;
}

fn bumpVersion(alloc: std.mem.Allocator, old: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, old, '+');
    const base = it.next() orelse return error.InvalidVersion;
    const build_str = it.next() orelse "0";
    const build_num = try std.fmt.parseInt(usize, build_str, 10) + 1;
    return std.fmt.allocPrint(alloc, "{s}+{d}", .{ base, build_num });
}
