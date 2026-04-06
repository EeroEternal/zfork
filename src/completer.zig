const std = @import("std");
const types = @import("types.zig");
const zconnector_bridge = @import("zconnector_bridge.zig");

pub const Completer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) Completer {
        return .{ .allocator = allocator, .io = io, .environ = environ };
    }

    pub fn complete(self: *const Completer, agent: ?*const types.Agent, options: types.CompletionOptions) ![]u8 {
        if (options.input.len == 0) return error.EmptyInput;

        const model = options.model orelse blk: {
            if (agent) |value| break :blk value.model;
            return error.MissingModel;
        };

        const prompt = options.prompt orelse blk: {
            if (agent) |value| break :blk value.prompt;
            break :blk defaultPrompt();
        };

        const normalized = std.mem.trim(u8, options.input, " \r\n");
        if (normalized.len == 0) return error.EmptyInput;

        const completion_prompt = try buildCompletionPrompt(self.allocator, normalized);
        defer self.allocator.free(completion_prompt);

        return try zconnector_bridge.complete(self.allocator, self.io, self.environ, .{
            .model = model,
            .system_prompt = prompt,
            .user_input = completion_prompt,
        });
    }
};

fn buildCompletionPrompt(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "You are a CLI completion engine. Return only the completed shell command or the best next command. No markdown. No explanation. Input: {s}",
        .{input},
    );
}

pub fn defaultPrompt() []const u8 {
    return "You are a professional shell command completion assistant. Return only the best command completion. No markdown. No explanation.";
}
