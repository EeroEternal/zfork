const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const local_agent = @import("local_agent.zig");
const remote_agent = @import("remote_agent.zig");

extern "c" fn cfmakeraw(termios_p: *std.posix.termios) void;

pub const AgentManager = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayList(types.Agent),
    state_dir_path: []u8,
    state_dir: std.fs.Dir,

    pub fn startAgent(self: *AgentManager, id: u64) !u32 {
        const agent = try self.getAgent(id);
        if (agent.pid) |pid| {
            if (isProcessRunning(pid)) return error.AgentAlreadyRunning;
            agent.pid = null;
        }

        try self.state_dir.makePath("run");
        try self.state_dir.makePath("logs");

        const socket_filename = try std.fmt.allocPrint(self.allocator, "agent-{d}.sock", .{agent.id});
        defer self.allocator.free(socket_filename);

        const log_filename = try std.fmt.allocPrint(self.allocator, "agent-{d}.log", .{agent.id});
        defer self.allocator.free(log_filename);

        const socket_path = try std.fs.path.join(self.allocator, &.{ "run", socket_filename });
        errdefer self.allocator.free(socket_path);

        const log_path = try std.fs.path.join(self.allocator, &.{ "logs", log_filename });
        errdefer self.allocator.free(log_path);

        const resize_path = try resizePathForAgent(self.allocator, agent.id);
        defer self.allocator.free(resize_path);

        const socket_abs_path = try absoluteStatePath(self, socket_path);
        defer self.allocator.free(socket_abs_path);

        const log_abs_path = try absoluteStatePath(self, log_path);
        defer self.allocator.free(log_abs_path);

        const resize_abs_path = try absoluteStatePath(self, resize_path);
        defer self.allocator.free(resize_abs_path);

        if (agent.socket_path) |path| self.allocator.free(path);
        if (agent.log_path) |path| self.allocator.free(path);
        agent.socket_path = socket_path;
        agent.log_path = log_path;

        const pid = switch (agent.kind) {
            .local => try local_agent.spawn(self.allocator, agent, socket_abs_path, log_abs_path, resize_abs_path),
            .remote => try remote_agent.spawn(self.allocator, agent, socket_abs_path, log_abs_path, resize_abs_path),
        };

        try waitForSocket(socket_abs_path);

        try self.save();
        return pid;
    }

    pub fn stopAgent(self: *AgentManager, id: u64) !void {
        const agent = try self.getAgent(id);
        const pid = agent.pid orelse return error.AgentNotRunning;

        const group_pid = -@as(std.posix.pid_t, @intCast(pid));
        std.posix.kill(group_pid, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };

        const resize_path = try resizePathForAgent(self.allocator, agent.id);
        defer self.allocator.free(resize_path);

        self.state_dir.deleteFile(resize_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        if (agent.socket_path) |path| {
            self.state_dir.deleteFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            self.allocator.free(path);
            agent.socket_path = null;
        }

        agent.pid = null;
        try self.save();
    }

    pub fn attachAgent(self: *AgentManager, id: u64, stdin_file: std.fs.File, stdout_file: std.fs.File) !void {
        const agent = try self.getAgent(id);
        const socket_path = agent.socket_path orelse return error.AgentNotRunning;
        const socket_abs_path = try absoluteStatePath(self, socket_path);
        defer self.allocator.free(socket_abs_path);

        const resize_path = try resizePathForAgent(self.allocator, agent.id);
        defer self.allocator.free(resize_path);
        const resize_abs_path = try absoluteStatePath(self, resize_path);
        defer self.allocator.free(resize_abs_path);

        const raw_mode = try RawTerminalMode.enter(stdin_file);
        defer raw_mode.restore();

        var resize_ctx = ResizeForwardContext{
            .stdin_file = stdin_file,
            .size_path = resize_abs_path,
        };
        const resize_thread = if (canTrackTerminalSize(stdin_file)) blk: {
            try writeCurrentTerminalSize(resize_abs_path, stdin_file);
            break :blk try std.Thread.spawn(.{}, forwardTerminalResize, .{&resize_ctx});
        } else null;
        defer if (resize_thread) |thread| {
            resize_ctx.requestStop();
            thread.join();
        };

        var stream = try std.net.connectUnixSocket(socket_abs_path);
        defer stream.close();

        const input_thread = try std.Thread.spawn(.{}, forwardInputToSocket, .{ stdin_file, stream.handle });
        input_thread.detach();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = stream.read(buffer[0..]) catch |err| switch (err) {
                error.ConnectionResetByPeer, error.SocketNotConnected => break,
                else => return err,
            };
            if (bytes_read == 0) break;
            try stdout_file.writeAll(buffer[0..bytes_read]);
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AgentManager {
        _ = io;
        const state_dir_path = try resolveStateDirPath(allocator);
        errdefer allocator.free(state_dir_path);

        try std.fs.cwd().makePath(state_dir_path);
        const state_dir = try std.fs.openDirAbsolute(state_dir_path, .{});

        var manager = AgentManager{
            .allocator = allocator,
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
        self.state_dir.close();
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
            null,
            null,
            null,
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

        try writer.writeAll("id\tstatus\trun\tkind\tpid\tmodel\thost\tname\n");
        for (self.agents.items) |agent| {
            try writer.print("{d}\t{s}\t{s}\t{s}\t", .{
                agent.id,
                agent.status.asString(),
                runtimeStatus(agent),
                agent.kind.asString(),
            });

            if (agent.pid) |pid| {
                try writer.print("{d}", .{pid});
            } else {
                try writer.writeAll("-");
            }

            try writer.print("\t{s}\t{s}\t{s}\n", .{
                agent.model,
                agent.host orelse "-",
                agent.name,
            });
        }
    }

    pub fn printAgentStatus(self: *const AgentManager, id: u64, writer: anytype) !void {
        const agent = self.findAgentConst(id) orelse return error.AgentNotFound;

        const socket_path = if (agent.socket_path) |path|
            try absoluteStatePath(self, path)
        else
            null;
        defer if (socket_path) |path| self.allocator.free(path);

        const log_path = if (agent.log_path) |path|
            try absoluteStatePath(self, path)
        else
            null;
        defer if (log_path) |path| self.allocator.free(path);

        try writer.print(
            "id: {d}\nname: {s}\nstatus: {s}\nrun: {s}\nkind: {s}\nmodel: {s}\nhost: {s}\npid: ",
            .{
                agent.id,
                agent.name,
                agent.status.asString(),
                runtimeStatus(agent.*),
                agent.kind.asString(),
                agent.model,
                agent.host orelse "-",
            },
        );

        if (agent.pid) |pid| {
            try writer.print("{d}\n", .{pid});
        } else {
            try writer.writeAll("-\n");
        }

        try writer.print("socket: {s}\nlog: {s}\n", .{
            socket_path orelse "-",
            log_path orelse "-",
        });
    }

    pub fn printAgentLogs(self: *AgentManager, id: u64, writer: anytype, follow: bool) !void {
        const agent = try self.getAgent(id);
        const log_path = agent.log_path orelse {
            try writer.writeAll("No logs available for this agent.\n");
            return;
        };

        var offset = try self.writeLogBytes(log_path, 0, writer);
        if (!follow) return;

        while (true) {
            std.Thread.sleep(100 * std.time.ns_per_ms);

            const next_offset = try self.writeLogBytes(log_path, offset, writer);
            const has_new_output = next_offset != offset;
            offset = next_offset;

            if (!runtimeIsAlive(agent) and !has_new_output) break;
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

    fn findAgentConst(self: *const AgentManager, id: u64) ?*const types.Agent {
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
        var file = self.state_dir.openFile("agents.tsv", .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        var reader_buffer: [4096]u8 = undefined;
        var reader = file.reader(&reader_buffer);
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
        var file = try self.state_dir.createFile("agents.tsv", .{ .truncate = true });
        defer file.close();

        var writer_buffer: [4096]u8 = undefined;
        var writer = file.writer(&writer_buffer);
        const out = &writer.interface;
        for (self.agents.items) |agent| {
            try validateField(agent.name);
            try validateField(agent.model);
            try validateField(agent.prompt);
            if (agent.host) |host| try validateField(host);
            if (agent.log_path) |path| try validateField(path);
            if (agent.socket_path) |path| try validateField(path);

            var pid_buffer: [32]u8 = undefined;
            const pid_text = if (agent.pid) |pid|
                try std.fmt.bufPrint(pid_buffer[0..], "{d}", .{pid})
            else
                "";

            try out.print(
                "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
                .{
                    agent.id,
                    agent.status.asString(),
                    agent.kind.asString(),
                    agent.name,
                    agent.model,
                    agent.prompt,
                    agent.host orelse "",
                    pid_text,
                    agent.log_path orelse "",
                    agent.socket_path orelse "",
                },
            );
        }
        try writer.interface.flush();
    }

    fn writeLogBytes(self: *AgentManager, log_path: []const u8, start_offset: u64, writer: anytype) !u64 {
        var file = try self.state_dir.openFile(log_path, .{});
        defer file.close();

        try file.seekTo(start_offset);

        var offset = start_offset;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try file.read(buffer[0..]);
            if (bytes_read == 0) break;

            offset += bytes_read;
            try writer.writeAll(buffer[0..bytes_read]);
            writer.flush() catch {};
        }

        return offset;
    }
};

fn parseAgentLine(allocator: std.mem.Allocator, line: []const u8) !types.Agent {
    var parts = std.mem.splitScalar(u8, line, '\t');
    var fields: [10][]const u8 = undefined;
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

    const pid: ?u32 = if (fields[7].len == 0) null else try std.fmt.parseUnsigned(u32, fields[7], 10);
    const log_path: ?[]const u8 = if (fields[8].len == 0) null else fields[8];
    const socket_path: ?[]const u8 = if (fields[9].len == 0) null else fields[9];

    var agent = try types.Agent.init(
        allocator,
        id,
        fields[3],
        fields[4],
        fields[5],
        host,
        status,
        pid,
        log_path,
        socket_path,
    );
    agent.kind = kind;
    return agent;
}

fn validateField(value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '\t') != null) return error.UnsupportedCharacterInField;
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return error.UnsupportedCharacterInField;
    if (std.mem.indexOfScalar(u8, value, '\r') != null) return error.UnsupportedCharacterInField;
}

fn resolveStateDirPath(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return resolveWindowsFallbackPath(allocator),
            else => return err,
        };
        defer allocator.free(appdata);
        return try std.fs.path.join(allocator, &.{ appdata, "zfork" });
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".zfork" });
}

fn resolveWindowsFallbackPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".zfork" });
}

fn forwardInputToSocket(stdin_file: std.fs.File, socket_handle: std.posix.socket_t) void {
    const stream = std.net.Stream{ .handle = socket_handle };
    var read_buffer: [256]u8 = undefined;
    var write_buffer: [256]u8 = undefined;
    var pending_prefix = false;

    while (true) {
        const bytes_read = stdin_file.read(read_buffer[0..]) catch break;
        if (bytes_read == 0) break;

        var write_len: usize = 0;
        for (read_buffer[0..bytes_read]) |byte| {
            if (pending_prefix) {
                pending_prefix = false;

                if (byte == 'd' or byte == 'D') {
                    if (write_len > 0) {
                        stream.writeAll(write_buffer[0..write_len]) catch break;
                    }
                    std.posix.shutdown(socket_handle, .send) catch {};
                    return;
                }

                if (byte == 0x01) {
                    write_buffer[write_len] = 0x01;
                    write_len += 1;
                    continue;
                }

                write_buffer[write_len] = 0x01;
                write_len += 1;
            }

            if (byte == 0x01) {
                pending_prefix = true;
                continue;
            }

            write_buffer[write_len] = byte;
            write_len += 1;

            if (write_len == write_buffer.len) {
                stream.writeAll(write_buffer[0..write_len]) catch break;
                write_len = 0;
            }
        }

        if (write_len > 0) {
            stream.writeAll(write_buffer[0..write_len]) catch break;
        }
    }

    if (pending_prefix) {
        stream.writeAll(&[_]u8{0x01}) catch {};
    }

    std.posix.shutdown(socket_handle, .send) catch {};
}

fn isProcessRunning(pid: u32) bool {
    std.posix.kill(@as(std.posix.pid_t, @intCast(pid)), 0) catch |err| switch (err) {
        error.PermissionDenied => return true,
        error.ProcessNotFound => return false,
        else => return false,
    };
    return true;
}

fn runtimeStatus(agent: types.Agent) []const u8 {
    if (runtimeIsAlive(&agent)) return "running";
    if (agent.pid != null) return "errored";
    return "stopped";
}

fn runtimeIsAlive(agent: *const types.Agent) bool {
    if (agent.pid) |pid| {
        return isProcessRunning(pid);
    }
    return false;
}

fn waitForSocket(socket_path: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        std.fs.accessAbsolute(socket_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Thread.sleep(20 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        return;
    }

    return error.SocketStartupTimeout;
}

fn absoluteStatePath(self: *const AgentManager, relative_path: []const u8) ![]u8 {
    return std.fs.path.join(self.allocator, &.{ self.state_dir_path, relative_path });
}

fn resizePathForAgent(allocator: std.mem.Allocator, id: u64) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "agent-{d}.winsize", .{id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ "run", filename });
}

fn canTrackTerminalSize(stdin_file: std.fs.File) bool {
    if (builtin.os.tag == .windows) return false;
    return std.posix.isatty(stdin_file.handle);
}

fn currentTerminalSize(stdin_file: std.fs.File) ?std.posix.winsize {
    if (!canTrackTerminalSize(stdin_file)) return null;

    var size: std.posix.winsize = undefined;
    if (std.posix.system.ioctl(stdin_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0) return null;
    if (size.row == 0 or size.col == 0) return null;
    return size;
}

fn writeCurrentTerminalSize(path: []const u8, stdin_file: std.fs.File) !void {
    const size = currentTerminalSize(stdin_file) orelse return;
    try writeWindowSizeFileAbsolute(path, size);
}

fn writeWindowSizeFileAbsolute(path: []const u8, size: std.posix.winsize) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    var buffer: [64]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.print("{d} {d}\n", .{ size.row, size.col });
    try writer.interface.flush();
}

fn sameWindowSize(lhs: std.posix.winsize, rhs: std.posix.winsize) bool {
    return lhs.row == rhs.row and lhs.col == rhs.col and lhs.xpixel == rhs.xpixel and lhs.ypixel == rhs.ypixel;
}

const ResizeForwardContext = struct {
    stdin_file: std.fs.File,
    size_path: []const u8,
    mutex: std.Thread.Mutex = .{},
    stop_requested: bool = false,

    fn requestStop(self: *ResizeForwardContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stop_requested = true;
    }

    fn shouldStop(self: *ResizeForwardContext) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stop_requested;
    }
};

fn forwardTerminalResize(ctx: *ResizeForwardContext) void {
    var last_size = currentTerminalSize(ctx.stdin_file);
    while (!ctx.shouldStop()) {
        std.Thread.sleep(100 * std.time.ns_per_ms);

        const size = currentTerminalSize(ctx.stdin_file) orelse continue;
        if (last_size) |previous| {
            if (sameWindowSize(previous, size)) continue;
        }

        writeWindowSizeFileAbsolute(ctx.size_path, size) catch {};
        last_size = size;
    }
}

const RawTerminalMode = struct {
    stdin_handle: std.posix.fd_t,
    original: ?std.posix.termios,

    fn enter(stdin_file: std.fs.File) !RawTerminalMode {
        if (builtin.os.tag == .windows) {
            return .{ .stdin_handle = stdin_file.handle, .original = null };
        }

        if (!std.posix.isatty(stdin_file.handle)) {
            return .{ .stdin_handle = stdin_file.handle, .original = null };
        }

        const original = try std.posix.tcgetattr(stdin_file.handle);
        var raw = original;
        cfmakeraw(&raw);
        try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);

        return .{
            .stdin_handle = stdin_file.handle,
            .original = original,
        };
    }

    fn restore(self: RawTerminalMode) void {
        if (self.original) |original| {
            std.posix.tcsetattr(self.stdin_handle, .NOW, original) catch {};
        }
    }
};
