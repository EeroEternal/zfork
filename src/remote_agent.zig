const std = @import("std");
const types = @import("types.zig");

pub fn attach(io: std.Io, agent: *const types.Agent) !void {
    const host = agent.host orelse return error.MissingRemoteHost;

    const argv = [_][]const u8{"ssh", host};
    var child = try std.process.spawn(io, .{
        .argv = argv[0..],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    _ = try child.wait(io);
}
