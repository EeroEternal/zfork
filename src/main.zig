const std = @import("std");
const agent_manager_mod = @import("agent_manager.zig");
const local_agent = @import("local_agent.zig");
const remote_agent = @import("remote_agent.zig");
const completer_mod = @import("completer.zig");
const notifier = @import("notifier.zig");
const types = @import("types.zig");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const io: std.Io = .{};
    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr_writer.interface.flush() catch {};
    const stderr = &stderr_writer.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printHelp(stdout);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "__serve-local")) {
        if (args.len < 6) return error.InvalidArgument;
        const initial_size = if (args.len >= 8) blk: {
            const row = try std.fmt.parseUnsigned(u16, args[6], 10);
            const col = try std.fmt.parseUnsigned(u16, args[7], 10);
            if (row == 0 or col == 0) break :blk null;
            break :blk std.posix.winsize{ .row = row, .col = col, .xpixel = 0, .ypixel = 0 };
        } else null;
        try local_agent.serve(allocator, args[2], args[3], args[4], args[5], initial_size);
        return;
    }

    if (std.mem.eql(u8, cmd, "__serve-remote")) {
        if (args.len < 6) return error.InvalidArgument;
        const initial_size = if (args.len >= 8) blk: {
            const row = try std.fmt.parseUnsigned(u16, args[6], 10);
            const col = try std.fmt.parseUnsigned(u16, args[7], 10);
            if (row == 0 or col == 0) break :blk null;
            break :blk std.posix.winsize{ .row = row, .col = col, .xpixel = 0, .ypixel = 0 };
        } else null;
        try remote_agent.serve(allocator, args[2], args[3], args[4], args[5], initial_size);
        return;
    }

    var manager = try agent_manager_mod.AgentManager.init(allocator, io);
    defer manager.deinit();

    if (std.mem.eql(u8, cmd, "new")) {
        const options = try parseNewArgs(args[2..]);
        const id = try manager.createAgent(options);
        try stdout.print("Created agent {d}\n", .{id});
        return;
    }

    if (std.mem.eql(u8, cmd, "list")) {
        try manager.listAgents(stdout);
        return;
    }

    if (std.mem.eql(u8, cmd, "status")) {
        const parsed = try parseStatusArgs(args[2..]);
        if (parsed.id) |id| {
            try manager.printAgentStatus(id, stdout);
        } else {
            try manager.listAgents(stdout);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "start")) {
        if (args.len < 3) return error.MissingAgentId;
        const id = try std.fmt.parseUnsigned(u64, args[2], 10);
        const pid = try manager.startAgent(id);
        try stdout.print("Started agent {d} (pid: {d})\n", .{ id, pid });
        return;
    }

    if (std.mem.eql(u8, cmd, "stop")) {
        if (args.len < 3) return error.MissingAgentId;
        const id = try std.fmt.parseUnsigned(u64, args[2], 10);
        try manager.stopAgent(id);
        try stdout.print("Stopped agent {d}\n", .{id});
        return;
    }

    if (std.mem.eql(u8, cmd, "logs")) {
        const parsed = try parseLogsArgs(args[2..]);
        try manager.printAgentLogs(parsed.id, stdout, parsed.follow);
        return;
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        if (args.len < 3) return error.MissingAgentId;
        const id = try std.fmt.parseUnsigned(u64, args[2], 10);
        try manager.attachAgent(id, stdin_file, stdout_file);
        return;
    }

    if (std.mem.eql(u8, cmd, "complete")) {
        const parsed = try parseCompleteArgs(args[2..]);
        const completer = completer_mod.Completer.init(allocator, io);
        const agent = if (parsed.model == null or parsed.prompt == null)
            manager.defaultCompletionAgent()
        else
            null;

        const completion = try completer.complete(agent, .{
            .input = parsed.input,
            .model = parsed.model,
            .prompt = parsed.prompt,
        });
        defer allocator.free(completion);

        try stdout.print("{s}\n", .{completion});
        try notifier.notifyCompletion(stderr, completion);
        return;
    }

    if (std.mem.eql(u8, cmd, "close")) {
        if (args.len < 3) return error.MissingAgentId;
        const id = try std.fmt.parseUnsigned(u64, args[2], 10);
        try manager.closeAgent(id);
        try stdout.print("Closed agent {d}\n", .{id});
        return;
    }

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        try printHelp(stdout);
        return;
    }

    try stderr.print("Unknown command: {s}\n\n", .{cmd});
    try printHelp(stderr);
    return error.UnknownCommand;
}

const ParsedCompleteArgs = struct {
    input: []const u8,
    model: ?[]const u8,
    prompt: ?[]const u8,
};

const ParsedLogsArgs = struct {
    id: u64,
    follow: bool,
};

const ParsedStatusArgs = struct {
    id: ?u64,
};

fn parseNewArgs(args: []const []const u8) !types.NewAgentOptions {
    var name: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var host: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return error.MissingName;
            name = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModel;
            model = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            prompt = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            host = args[i];
            continue;
        }
        return error.InvalidArgument;
    }

    return .{
        .name = name orelse return error.MissingName,
        .model = model orelse return error.MissingModel,
        .prompt = prompt orelse completer_mod.defaultPrompt(),
        .host = host,
    };
}

fn parseCompleteArgs(args: []const []const u8) !ParsedCompleteArgs {
    var input: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModel;
            model = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            prompt = args[i];
            continue;
        }
        if (input == null) {
            input = arg;
            continue;
        }
        return error.InvalidArgument;
    }

    return .{
        .input = input orelse return error.MissingCompletionInput,
        .model = model,
        .prompt = prompt,
    };
}

fn parseLogsArgs(args: []const []const u8) !ParsedLogsArgs {
    var id: ?u64 = null;
    var follow = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            follow = true;
            continue;
        }

        if (id == null) {
            id = try std.fmt.parseUnsigned(u64, arg, 10);
            continue;
        }

        return error.InvalidArgument;
    }

    return .{
        .id = id orelse return error.MissingAgentId,
        .follow = follow,
    };
}

fn parseStatusArgs(args: []const []const u8) !ParsedStatusArgs {
    if (args.len == 0) return .{ .id = null };
    if (args.len == 1) {
        return .{ .id = try std.fmt.parseUnsigned(u64, args[0], 10) };
    }
    return error.InvalidArgument;
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll("zfork - Zig Agent Fork\n" ++
        "\n" ++
        "Usage:\n" ++
        "  zfork new -n <name> -m <model> [-p <prompt>] [-H <host>]\n" ++
        "  zfork list\n" ++
        "  zfork status [id]\n" ++
        "  zfork start <id>\n" ++
        "  zfork stop <id>\n" ++
        "  zfork logs <id> [-f]\n" ++
        "  zfork attach <id>\n" ++
        "  zfork complete <input> [-m <model>] [-p <prompt>]\n" ++
        "  zfork close <id>\n" ++
        "  zfork --help\n");
}
