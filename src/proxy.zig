const std = @import("std");
const builtin = @import("builtin");

const tiocswinsz: c_int = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => @bitCast(@as(u32, 0x80087467)),
    else => std.c.T.IOCSWINSZ,
};

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const std.posix.winsize,
) c_int;

extern "c" fn login_tty(fd: c_int) c_int;

const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    log_file: std.fs.File,
    child_io: std.fs.File,
    client: ?std.net.Stream = null,
    shutting_down: bool = false,

    fn broadcast(self: *SharedState, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.log_file.writeAll(bytes) catch {};
        if (self.client) |client| {
            client.writeAll(bytes) catch {
                client.close();
                self.client = null;
            };
        }
    }

    fn tryAttachClient(self: *SharedState, client: std.net.Stream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down or self.client != null) return false;
        self.client = client;
        return true;
    }

    fn detachClient(self: *SharedState, handle: std.posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.client) |client| {
            if (client.handle == handle) {
                self.client = null;
            }
        }
    }

    fn beginShutdown(self: *SharedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shutting_down = true;
        if (self.client) |client| {
            client.close();
            self.client = null;
        }
    }

    fn isShuttingDown(self: *SharedState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.shutting_down;
    }
};

const PipeContext = struct {
    state: *SharedState,
    file: std.fs.File,
};

const AcceptContext = struct {
    state: *SharedState,
    server: *std.net.Server,
};

const ResizeContext = struct {
    state: *SharedState,
    size_path: []const u8,
    pty_handle: std.posix.fd_t,
    last_size: ?std.posix.winsize,
};

pub fn runCommandServer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    log_path: []const u8,
    argv: []const []const u8,
) !void {
    std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{});
    var server_open = true;
    defer if (server_open) server.deinit();
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = true });
    defer log_file.close();

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var state = SharedState{
        .log_file = log_file,
        .child_io = child.stdin.?,
    };

    var stdout_ctx = PipeContext{ .state = &state, .file = child.stdout.? };
    var stderr_ctx = PipeContext{ .state = &state, .file = child.stderr.? };
    var accept_ctx = AcceptContext{ .state = &state, .server = &server };

    const stdout_thread = try std.Thread.spawn(.{}, pipeChildOutput, .{&stdout_ctx});
    const stderr_thread = try std.Thread.spawn(.{}, pipeChildOutput, .{&stderr_ctx});
    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{&accept_ctx});

    _ = try child.wait();

    state.beginShutdown();
    state.child_io.close();
    if (server_open) {
        server.deinit();
        server_open = false;
    }

    accept_thread.join();
    stdout_thread.join();
    stderr_thread.join();
}

const PtyChild = struct {
    pid: std.posix.pid_t,
    master: std.fs.File,
};

pub fn runPtyCommandServer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    log_path: []const u8,
    size_path: []const u8,
    argv: []const []const u8,
    initial_size: ?std.posix.winsize,
) !void {
    std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{});
    var server_open = true;
    defer if (server_open) server.deinit();
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    std.fs.deleteFileAbsolute(size_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(size_path) catch {};

    var log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = true });
    defer log_file.close();

    const pty_child = try spawnPtyChild(allocator, argv, initial_size);
    errdefer {
        std.posix.kill(pty_child.pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(pty_child.pid, 0);
    }

    var state = SharedState{
        .log_file = log_file,
        .child_io = pty_child.master,
    };

    var output_ctx = PipeContext{ .state = &state, .file = pty_child.master };
    var accept_ctx = AcceptContext{ .state = &state, .server = &server };
    var resize_ctx = ResizeContext{
        .state = &state,
        .size_path = size_path,
        .pty_handle = pty_child.master.handle,
        .last_size = initial_size,
    };

    if (initial_size) |size| {
        try writeWindowSizeFile(size_path, size);
    }

    const output_thread = try std.Thread.spawn(.{}, pipeChildOutput, .{&output_ctx});
    const accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{&accept_ctx});
    const resize_thread = try std.Thread.spawn(.{}, watchWindowSize, .{&resize_ctx});

    _ = std.posix.waitpid(pty_child.pid, 0);

    state.beginShutdown();
    state.child_io.close();
    if (server_open) {
        server.deinit();
        server_open = false;
    }

    accept_thread.join();
    output_thread.join();
    resize_thread.join();
}

fn pipeChildOutput(ctx: *PipeContext) void {
    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = ctx.file.read(buffer[0..]) catch return;
        if (bytes_read == 0) return;
        ctx.state.broadcast(buffer[0..bytes_read]);
    }
}

fn acceptLoop(ctx: *AcceptContext) void {
    while (true) {
        var conn = ctx.server.accept() catch {
            if (ctx.state.isShuttingDown()) return;
            return;
        };

        if (!ctx.state.tryAttachClient(conn.stream)) {
            conn.stream.writeAll("Another client is already attached.\n") catch {};
            conn.stream.close();
            continue;
        }

        handleClientInput(ctx.state, conn.stream);
        ctx.state.detachClient(conn.stream.handle);
        conn.stream.close();
    }
}

fn handleClientInput(state: *SharedState, stream: std.net.Stream) void {
    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = stream.read(buffer[0..]) catch return;
        if (bytes_read == 0) return;

        state.child_io.writeAll(buffer[0..bytes_read]) catch return;
    }
}

fn watchWindowSize(ctx: *ResizeContext) void {
    while (!ctx.state.isShuttingDown()) {
        if (readWindowSizeFile(ctx.size_path)) |size| {
            if (ctx.last_size == null or !sameWindowSize(ctx.last_size.?, size)) {
                applyWindowSize(ctx.pty_handle, size);
                ctx.last_size = size;
            }
        } else |_| {}

        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

fn applyWindowSize(handle: std.posix.fd_t, size: std.posix.winsize) void {
    var mutable = size;
    _ = std.posix.system.ioctl(handle, tiocswinsz, @intFromPtr(&mutable));
}

fn writeWindowSizeFile(path: []const u8, size: std.posix.winsize) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    var buffer: [64]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.print("{d} {d}\n", .{ size.row, size.col });
    try writer.interface.flush();
}

fn readWindowSizeFile(path: []const u8) !std.posix.winsize {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buffer: [64]u8 = undefined;
    const bytes_read = try file.readAll(buffer[0..]);
    const contents = std.mem.trim(u8, buffer[0..bytes_read], " \t\r\n");
    if (contents.len == 0) return error.InvalidWindowSize;

    var parts = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    const row_text = parts.next() orelse return error.InvalidWindowSize;
    const col_text = parts.next() orelse return error.InvalidWindowSize;
    const row = try std.fmt.parseUnsigned(u16, row_text, 10);
    const col = try std.fmt.parseUnsigned(u16, col_text, 10);
    if (row == 0 or col == 0) return error.InvalidWindowSize;

    return .{ .row = row, .col = col, .xpixel = 0, .ypixel = 0 };
}

fn sameWindowSize(lhs: std.posix.winsize, rhs: std.posix.winsize) bool {
    return lhs.row == rhs.row and lhs.col == rhs.col and lhs.xpixel == rhs.xpixel and lhs.ypixel == rhs.ypixel;
}

fn spawnPtyChild(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    initial_size: ?std.posix.winsize,
) !PtyChild {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const z_argv = try allocNullTerminatedArgv(arena.allocator(), argv);
    var env_map = try std.process.getEnvMap(arena.allocator());
    const envp = try std.process.createNullDelimitedEnvMap(arena.allocator(), &env_map);

    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    const winsize_ptr = if (initial_size) |size| blk: {
        const ptr = try arena.allocator().create(std.posix.winsize);
        ptr.* = size;
        break :blk ptr;
    } else null;

    if (openpty(&master_fd, &slave_fd, null, null, winsize_ptr) == -1) {
        return error.OpenPtyFailed;
    }
    errdefer std.posix.close(master_fd);
    errdefer std.posix.close(slave_fd);

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(master_fd);
        if (login_tty(slave_fd) == -1) std.posix.exit(1);
        std.posix.execvpeZ(z_argv[0].?, z_argv.ptr, envp.ptr) catch std.posix.exit(1);
    }

    std.posix.close(slave_fd);
    return .{
        .pid = pid,
        .master = .{ .handle = master_fd },
    };
}

fn allocNullTerminatedArgv(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ![:null]?[*:0]const u8 {
    const result = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, index| {
        result[index] = (try allocator.dupeZ(u8, arg)).ptr;
    }
    return result;
}
