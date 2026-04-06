const std = @import("std");

pub const AgentKind = enum {
    local,
    remote,

    pub fn fromHost(host: ?[]const u8) AgentKind {
        return if (host != null) .remote else .local;
    }

    pub fn asString(self: AgentKind) []const u8 {
        return switch (self) {
            .local => "local",
            .remote => "remote",
        };
    }

    pub fn parse(value: []const u8) !AgentKind {
        if (std.mem.eql(u8, value, "local")) return .local;
        if (std.mem.eql(u8, value, "remote")) return .remote;
        return error.InvalidAgentKind;
    }
};

pub const AgentStatus = enum {
    open,
    closed,

    pub fn asString(self: AgentStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .closed => "closed",
        };
    }

    pub fn parse(value: []const u8) !AgentStatus {
        if (std.mem.eql(u8, value, "open")) return .open;
        if (std.mem.eql(u8, value, "closed")) return .closed;
        return error.InvalidAgentStatus;
    }
};

pub const Agent = struct {
    id: u64,
    name: []u8,
    model: []u8,
    prompt: []u8,
    host: ?[]u8,
    kind: AgentKind,
    status: AgentStatus,

    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        name: []const u8,
        model: []const u8,
        prompt: []const u8,
        host: ?[]const u8,
        status: AgentStatus,
    ) !Agent {
        return .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .model = try allocator.dupe(u8, model),
            .prompt = try allocator.dupe(u8, prompt),
            .host = if (host) |value| try allocator.dupe(u8, value) else null,
            .kind = AgentKind.fromHost(host),
            .status = status,
        };
    }

    pub fn deinit(self: *Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.model);
        allocator.free(self.prompt);
        if (self.host) |host| allocator.free(host);
    }
};

pub const NewAgentOptions = struct {
    name: []const u8,
    model: []const u8,
    prompt: []const u8,
    host: ?[]const u8 = null,
};

pub const CompletionOptions = struct {
    input: []const u8,
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};
