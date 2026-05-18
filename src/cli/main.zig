const std = @import("std");
const lib = @import("libchroma");
const Action = @import("action.zig").Action;
const fmt = @import("format.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(init.io, &buf);
        const stderr = &w.interface;
        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args = if (comptime @import("builtin").os.tag == .windows)
        try init.minimal.args.iterateAllocator(alloc)
    else
        init.minimal.args.iterate();
    _ = args.skip(); // program name

    const cmd = args.next();

    if (cmd == null) {
        printUsage(init.io, std.Io.File.stderr());
        return;
    }

    if (std.mem.eql(u8, cmd.?, "--help") or std.mem.eql(u8, cmd.?, "-h")) {
        printUsage(init.io, std.Io.File.stdout());
        return;
    }

    if (std.meta.stringToEnum(Action, cmd.?)) |action| {
        return action.run(alloc, init.io, &args);
    }

    printUsage(init.io, std.Io.File.stderr());
}

fn printUsage(io: std.Io, file: std.Io.File) void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    const out = &w.interface;
    out.print(
        \\Usage: chroma <command> [args]
        \\
        \\Commands:
        \\  convert <color> <space>   Convert a color to a target space
        \\  info <color>              Show a color in all spaces
        \\
        \\Color formats: #RRGGBB, RRGGBB, space(v1, v2, v3)
        \\
    , .{}) catch {};
    out.print("Spaces:\n", .{}) catch {};
    inline for (@typeInfo(lib.Space).@"enum".fields) |field| {
        const space: lib.Space = @enumFromInt(field.value);
        out.print("  {s}\n", .{comptime fmt.spaceCliName(space)}) catch {};
    }
    out.flush() catch {};
}
