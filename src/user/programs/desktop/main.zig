const common = @import("common");
const assert = common.assert;
const field_size = common.field_size;
pub const logger = common.log.scoped(.main);

const Desktop = @import("desktop.zig");
const Message = common.Message;

const user = @import("user");
pub const panic = user.panic;
pub const log = user.log;
const Syscall = user.Syscall;

//const text = @import("../../text.zig");

pub var syscall_manager: *Syscall.Manager = undefined;

fn send_message(id: Message.ID, context: ?*anyopaque) void {
    _ = syscall_manager.syscall(.send_message, .blocking, .{ .id = id, .context = context });
}

fn receive_message() Message {
    const message = syscall_manager.syscall(.receive_message, .blocking, .{});
    return message;
}

export fn user_entry_point() callconv(.C) void {
    syscall_manager = Syscall.Manager.ask() orelse @panic("wtf");

    send_message(.desktop_setup_ui, null);

    while (true) {
        const message = receive_message();
        Desktop.send_message(message);
    }
}
