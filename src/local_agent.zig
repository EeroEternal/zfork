const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub fn attach(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, agent: *const types.Agent) !void {
    _ = agent;

    const shell = try resolveShell(allocator, environ);
    defer allocator.free(shell);

    const argv = [_][]const u8{shell};
    var child = try std.process.spawn(io, .{
        .argv = argv[0..],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    _ = try child.wait(io);
}

fn resolveShell(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const env_name = if (builtin.os.tag == .windows) "COMSPEC" else "SHELL";
    return std.process.Environ.getAlloc(environ, allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => allocator.dupe(
            u8,
            if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh",
        ),
        else => err,
    };
}
