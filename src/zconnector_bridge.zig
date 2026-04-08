const std = @import("std");
const zc = @import("zconnector");

pub const Request = struct {
    model: []const u8,
    system_prompt: []const u8,
    user_input: []const u8,
};

pub fn complete(allocator: std.mem.Allocator, io: std.Io, request: Request) ![]u8 {
    // 优先从环境变量读取 API Key，否则报错
    const api_key = std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.MissingApiKey,
        else => return err,
    };
    defer allocator.free(api_key);

    // 优先从环境变量读取自定义 Base URL，否则默认 OpenAI
    const base_url = std.process.getEnvVarOwned(allocator, "OPENAI_BASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "https://api.openai.com"),
        else => return err,
    };
    defer allocator.free(base_url);

    var client = try zc.LlmClient.openai(allocator, api_key, base_url, io);
    defer client.deinit();

    var chat_request = try zc.ChatRequest.fromTextMessages(allocator, request.model, &.{
        .{ .role = .system, .content = request.system_prompt },
        .{ .role = .user, .content = request.user_input },
    });
    defer chat_request.deinit();

    var response = try client.chat(&chat_request, .{ .io = io });
    defer response.deinit();

    if (response.content.len == 0) return error.EmptyCompletion;
    return allocator.dupe(u8, response.content);
}
