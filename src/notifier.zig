pub fn bell(writer: anytype) !void {
    try writer.writeByte('\x07');
}

pub fn notify(writer: anytype, title: []const u8, message: []const u8) !void {
    try bell(writer);
    try writer.print("\n[zfork] {s}: {s}\n", .{ title, message });
}

pub fn notifyCompletion(writer: anytype, completion: []const u8) !void {
    try notify(writer, "completion", completion);
}
