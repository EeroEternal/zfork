const std = @import("std");

pub const Request = struct {
    model: []const u8,
    system_prompt: []const u8,
    user_input: []const u8,
};

pub fn complete(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, request: Request) ![]u8 {
    const command = std.process.Environ.getAlloc(environ, allocator, "ZFORK_ZCONNECTOR_CMD") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, "zconnector"),
        else => return err,
    };
    defer allocator.free(command);

    const prompt = try std.fmt.allocPrint(
        allocator,
        "model={s}\nsystem={s}\ninput={s}\n",
        .{ request.model, request.system_prompt, request.user_input },
    );
    defer allocator.free(prompt);

    const argv = [_][]const u8{command};
    var child = try std.process.spawn(io, .{
        .argv = argv[0..],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (child.stdin) |stdin| {
        try stdin.writeStreamingAll(io, prompt);
        stdin.close(io);
    }

    const stdout = if (child.stdout) |stdout| blk: {
        var reader = stdout.reader(io, &.{});
        break :blk reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
    } else try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);

    const stderr = if (child.stderr) |stderr| blk: {
        var reader = stderr.reader(io, &.{});
        break :blk reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
    } else try allocator.dupe(u8, "");
    defer allocator.free(stderr);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("zconnector failed: {s}\n", .{stderr});
                return error.ZconnectorFailed;
            }
        },
        else => return error.ZconnectorFailed,
    }

    const trimmed = std.mem.trim(u8, stdout, " \r\n");
    if (trimmed.len == 0) return error.EmptyCompletion;
    if (trimmed.ptr == stdout.ptr and trimmed.len == stdout.len) return stdout;

    const result = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return result;
}
