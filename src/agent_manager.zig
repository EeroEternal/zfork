const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub const AgentManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    agents: std.ArrayList(types.Agent),
    state_dir_path: []u8,
    state_dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !AgentManager {
        const state_dir_path = try resolveStateDirPath(allocator, environ);
        errdefer allocator.free(state_dir_path);

        try std.Io.Dir.cwd().createDirPath(io, state_dir_path);
        const state_dir = try std.Io.Dir.openDirAbsolute(io, state_dir_path, .{});

        var manager = AgentManager{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .agents = .empty,
            .state_dir_path = state_dir_path,
            .state_dir = state_dir,
        };
        errdefer manager.deinit();

        try manager.load();
        return manager;
    }

    pub fn deinit(self: *AgentManager) void {
        for (self.agents.items) |*agent| {
            agent.deinit(self.allocator);
        }
        self.agents.deinit(self.allocator);
        self.state_dir.close(self.io);
        self.allocator.free(self.state_dir_path);
    }

    pub fn createAgent(self: *AgentManager, options: types.NewAgentOptions) !u64 {
        try validateField(options.name);
        try validateField(options.model);
        try validateField(options.prompt);
        if (options.host) |host| try validateField(host);

        const id = self.nextId();
        const agent = try types.Agent.init(
            self.allocator,
            id,
            options.name,
            options.model,
            options.prompt,
            options.host,
            .open,
        );
        try self.agents.append(self.allocator, agent);
        try self.save();
        return id;
    }

    pub fn listAgents(self: *const AgentManager, writer: anytype) !void {
        if (self.agents.items.len == 0) {
            try writer.writeAll("No agents found.\n");
            return;
        }

        try writer.writeAll("id\tstatus\tkind\tmodel\thost\tname\n");
        for (self.agents.items) |agent| {
            try writer.print(
                "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
                .{
                    agent.id,
                    agent.status.asString(),
                    agent.kind.asString(),
                    agent.model,
                    agent.host orelse "-",
                    agent.name,
                },
            );
        }
    }

    pub fn getAgent(self: *AgentManager, id: u64) !*types.Agent {
        return self.findAgent(id) orelse error.AgentNotFound;
    }

    pub fn defaultCompletionAgent(self: *const AgentManager) ?*const types.Agent {
        var index = self.agents.items.len;
        while (index > 0) {
            index -= 1;
            const agent = &self.agents.items[index];
            if (agent.status == .open) return agent;
        }
        return null;
    }

    pub fn closeAgent(self: *AgentManager, id: u64) !void {
        const agent = try self.getAgent(id);
        agent.status = .closed;
        try self.save();
    }

    fn findAgent(self: *AgentManager, id: u64) ?*types.Agent {
        for (self.agents.items) |*agent| {
            if (agent.id == id) return agent;
        }
        return null;
    }

    fn nextId(self: *const AgentManager) u64 {
        var max_id: u64 = 0;
        for (self.agents.items) |agent| {
            if (agent.id > max_id) max_id = agent.id;
        }
        return max_id + 1;
    }

    fn load(self: *AgentManager) !void {
        var file = self.state_dir.openFile(self.io, "agents.tsv", .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);

        var reader_buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &reader_buffer);
        const contents = reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;
            const agent = try parseAgentLine(self.allocator, trimmed);
            try self.agents.append(self.allocator, agent);
        }
    }

    fn save(self: *AgentManager) !void {
        var file = try self.state_dir.createFile(self.io, "agents.tsv", .{ .truncate = true });
        defer file.close(self.io);

        var writer_buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &writer_buffer);
        const out = &writer.interface;
        for (self.agents.items) |agent| {
            try validateField(agent.name);
            try validateField(agent.model);
            try validateField(agent.prompt);
            if (agent.host) |host| try validateField(host);

            try out.print(
                "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
                .{
                    agent.id,
                    agent.status.asString(),
                    agent.kind.asString(),
                    agent.name,
                    agent.model,
                    agent.prompt,
                    agent.host orelse "",
                },
            );
        }
        try writer.flush();
    }
};

fn parseAgentLine(allocator: std.mem.Allocator, line: []const u8) !types.Agent {
    var parts = std.mem.splitScalar(u8, line, '\t');
    var fields: [7][]const u8 = undefined;
    var count: usize = 0;

    while (parts.next()) |part| {
        if (count >= fields.len) return error.InvalidStateLine;
        fields[count] = part;
        count += 1;
    }

    if (count != fields.len) return error.InvalidStateLine;

    const id = try std.fmt.parseUnsigned(u64, fields[0], 10);
    const status = try types.AgentStatus.parse(fields[1]);
    const kind = try types.AgentKind.parse(fields[2]);
    const host: ?[]const u8 = if (fields[6].len == 0) null else fields[6];

    if (kind == .remote and host == null) return error.InvalidStateLine;
    if (kind == .local and host != null) return error.InvalidStateLine;

    var agent = try types.Agent.init(
        allocator,
        id,
        fields[3],
        fields[4],
        fields[5],
        host,
        status,
    );
    agent.kind = kind;
    return agent;
}

fn validateField(value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '\t') != null) return error.UnsupportedCharacterInField;
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return error.UnsupportedCharacterInField;
    if (std.mem.indexOfScalar(u8, value, '\r') != null) return error.UnsupportedCharacterInField;
}

fn resolveStateDirPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.process.Environ.getAlloc(environ, allocator, "APPDATA") catch |err| switch (err) {
            error.EnvironmentVariableMissing => return resolveWindowsFallbackPath(allocator, environ),
            else => return err,
        };
        defer allocator.free(appdata);
        return try std.Io.Dir.path.join(allocator, &.{ appdata, "zfork" });
    }

    const home = try std.process.Environ.getAlloc(environ, allocator, "HOME");
    defer allocator.free(home);
    return try std.Io.Dir.path.join(allocator, &.{ home, ".zfork" });
}

fn resolveWindowsFallbackPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const home = try std.process.Environ.getAlloc(environ, allocator, "USERPROFILE");
    defer allocator.free(home);
    return try std.Io.Dir.path.join(allocator, &.{ home, ".zfork" });
}
