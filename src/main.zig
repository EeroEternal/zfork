const std = @import("std");
const agent_manager_mod = @import("agent_manager.zig");
const local_agent = @import("local_agent.zig");
const remote_agent = @import("remote_agent.zig");
const completer_mod = @import("completer.zig");
const notifier = @import("notifier.zig");
const types = @import("types.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    defer stdout_writer.flush() catch {};
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    defer stderr_writer.flush() catch {};
    const stderr = &stderr_writer.interface;

    var manager = try agent_manager_mod.AgentManager.init(allocator, io, environ);
    defer manager.deinit();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    while (args_iter.next()) |arg| {
        try args.append(allocator, arg);
    }

    if (args.items.len < 2) {
        try printHelp(stdout);
        return;
    }

    const cmd = args.items[1];
    if (std.mem.eql(u8, cmd, "new")) {
        const options = try parseNewArgs(args.items[2..]);
        const id = try manager.createAgent(options);
        try stdout.print("Created agent {d}\n", .{id});
        return;
    }

    if (std.mem.eql(u8, cmd, "list")) {
        try manager.listAgents(stdout);
        return;
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        if (args.items.len < 3) return error.MissingAgentId;
        const id = try std.fmt.parseUnsigned(u64, args.items[2], 10);
        const agent = try manager.getAgent(id);
        switch (agent.kind) {
            .local => try local_agent.attach(io, allocator, agent),
            .remote => try remote_agent.attach(io, agent),
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "complete")) {
        const parsed = try parseCompleteArgs(args.items[2..]);
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
        if (args.items.len < 3) return error.MissingAgentId;
        const id = try std.fmt.parseUnsigned(u64, args.items[2], 10);
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

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        "zfork - Zig Agent Fork\n" ++
            "\n" ++
            "Usage:\n" ++
            "  zfork new -n <name> -m <model> [-p <prompt>] [-H <host>]\n" ++
            "  zfork list\n" ++
            "  zfork attach <id>\n" ++
            "  zfork complete <input> [-m <model>] [-p <prompt>]\n" ++
            "  zfork close <id>\n" ++
            "  zfork --help\n"
    );
}
