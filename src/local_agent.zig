const std = @import("std");
const builtin = @import("builtin");
const proxy = @import("proxy.zig");
const types = @import("types.zig");

pub fn spawn(
    allocator: std.mem.Allocator,
    agent: *types.Agent,
    socket_path: []const u8,
    log_path: []const u8,
    resize_path: []const u8,
) !u32 {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    const shell = try resolveShell(allocator);
    defer allocator.free(shell);

    const size = currentTerminalSize();
    var row_buffer: [16]u8 = undefined;
    var col_buffer: [16]u8 = undefined;
    const row_text = try std.fmt.bufPrint(row_buffer[0..], "{d}", .{if (size) |value| value.row else 0});
    const col_text = try std.fmt.bufPrint(col_buffer[0..], "{d}", .{if (size) |value| value.col else 0});

    const argv = [_][]const u8{ self_exe, "__serve-local", socket_path, log_path, resize_path, shell, row_text, col_text };
    var child = std.process.Child.init(argv[0..], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();

    const pid = std.math.cast(u32, child.id) orelse return error.InvalidProcessId;
    agent.pid = pid;
    return pid;
}

pub fn serve(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    log_path: []const u8,
    resize_path: []const u8,
    shell: []const u8,
    initial_size: ?std.posix.winsize,
) !void {
    const argv = [_][]const u8{shell};
    try proxy.runPtyCommandServer(allocator, socket_path, log_path, resize_path, argv[0..], initial_size);
}

fn resolveShell(allocator: std.mem.Allocator) ![]u8 {
    const env_name = if (builtin.os.tag == .windows) "COMSPEC" else "SHELL";
    return std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(
            u8,
            if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh",
        ),
        else => err,
    };
}

fn currentTerminalSize() ?std.posix.winsize {
    const stdin_handle = std.fs.File.stdin().handle;
    if (!std.posix.isatty(stdin_handle)) return null;

    var size: std.posix.winsize = undefined;
    if (std.posix.system.ioctl(stdin_handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0) return null;
    if (size.row == 0 or size.col == 0) return null;
    return size;
}
