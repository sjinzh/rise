const lib = @import("lib");
const assert = lib.assert;
const enumCount = lib.enumCount;
const log = lib.log.scoped(.Syscall);

comptime {
    if (lib.os != .freestanding) @compileError("This file should not be imported in build.zig");
}

pub const Options = packed struct(u8) {
    execution_mode: ExecutionMode,
    type: Type,
    unused: u6 = 0,

    comptime {
        assert(@bitSizeOf(Options) == @bitSizeOf(u8));
    }
};

pub const Type = enum(u1) {
    syscall = 0,
    service = 1,
};

pub const ExecutionMode = enum(u1) {
    blocking,
    non_blocking,
    const count = enumCount(@This());
};

pub const services = blk: {
    var service_descriptors: [Service.count]Service = undefined;
    add_service_descriptor(Service{
        .id = .thread_exit,
        .Parameters = struct {
            message: ?[]const u8 = null,
            exit_code: u64 = 0,
        },
        .Result = noreturn,
        .Error = error{
            empty_message,
        },
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .log,
        .Parameters = struct {
            message: []const u8,
        },
        .Result = void,
        .Error = error{
            empty_string,
            null_string,
        },
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .read_file,
        .Parameters = struct {
            filename: []const u8,
        },
        .Result = []const u8,
        .Error = error{
            empty_string,
            null_string,
        },
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .allocate_memory,
        .Parameters = struct {
            size: u64,
            alignment: u64,
        },
        .Result = []u8,
        .Error = error{
            size_is_zero,
            alignment_is_zero,
        },
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .get_framebuffer,
        .Parameters = void,
        .Result = *lib.Graphics.DrawingArea,
        .Error = error{},
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .send_message,
        .Parameters = struct {
            message: lib.Message,
        },
        .Result = void,
        .Error = error{
            invalid_message_id,
        },
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .receive_message,
        .Parameters = void,
        .Result = lib.Message,
        .Error = error{},
    }, &service_descriptors);
    add_service_descriptor(Service{
        .id = .create_plain_window,
        .Parameters = struct {
            user_window: *lib.Window,
        },
        .Result = void,
        .Error = error{},
    }, &service_descriptors);
    break :blk service_descriptors;
};

pub const Submission = struct {
    input: Input,
    arguments: Arguments,

    fn from_service(id: Service.ID, arguments: Submission.Arguments) Submission {
        const input = Input{
            .id = @enumToInt(id),
            .options = .{
                .execution_mode = .blocking,
                .type = .service,
            },
        };
        return Submission{ .input = input, .arguments = arguments };
    }

    pub fn from_parameters(comptime service: Service, parameters: service.Parameters) service.Error!Submission {
        const arguments: Submission.Arguments = blk: {
            switch (service.id) {
                .thread_exit => {
                    var message_ptr: ?[*]const u8 = undefined;
                    var message_len: u64 = undefined;
                    if (parameters.message) |message| {
                        if (message.len == 0) return service.Error.empty_message;
                        message_ptr = message.ptr;
                        message_len = message.len;
                    } else {
                        message_ptr = null;
                        message_len = 0;
                    }

                    break :blk .{ parameters.exit_code, @ptrToInt(message_ptr), message_len, 0, 0 };
                },
                .log => {
                    if (parameters.message.len == 0) return service.Error.empty_string;
                    break :blk .{ @ptrToInt(parameters.message.ptr), parameters.message.len, 0, 0, 0 };
                },
                .read_file => {
                    if (parameters.filename.len == 0) return service.Error.empty_filename;
                    break :blk .{ @ptrToInt(parameters.filename.ptr), parameters.filename.len, 0, 0, 0 };
                },
                .allocate_memory => {
                    if (parameters.size == 0) return service.Error.size_is_zero;
                    if (parameters.alignment == 0) return service.Error.alignment_is_zero;
                    break :blk .{ parameters.size, parameters.alignment, 0, 0, 0 };
                },
                .get_framebuffer => {
                    comptime assert(@TypeOf(parameters) == void);
                    break :blk .{ 0, 0, 0, 0, 0 };
                },
                .receive_message => {
                    comptime assert(@TypeOf(parameters) == void);
                    break :blk .{ 0, 0, 0, 0, 0 };
                },
                .send_message => {
                    const message = parameters.message;
                    break :blk .{ @enumToInt(message.id), @ptrToInt(message.context), 0, 0, 0 };
                },
                .create_plain_window => {
                    break :blk .{ @ptrToInt(parameters.user_window), 0, 0, 0, 0 };
                },
            }
        };

        return Submission.from_service(service.id, arguments);
    }

    pub fn to_parameters(submission: Submission, comptime service: Service) service.Error!service.Parameters {
        return switch (service.id) {
            .thread_exit => blk: {
                const message = msg_blk: {
                    if (@intToPtr(?[*]const u8, submission.arguments[1])) |message_ptr| {
                        const message_len = submission.arguments[2];
                        if (message_len == 0) return service.Error.empty_message;
                        break :msg_blk message_ptr[0..message_len];
                    } else {
                        break :msg_blk null;
                    }
                };

                break :blk .{
                    .exit_code = submission.arguments[0],
                    .message = message,
                };
            },
            .log => blk: {
                if (@intToPtr(?[*]const u8, submission.arguments[0])) |message_ptr| {
                    const message_len = submission.arguments[1];
                    if (message_len == 0) return service.Error.empty_string;
                    break :blk .{ .message = message_ptr[0..message_len] };
                } else {
                    return service.Error.null_string;
                }
            },
            .read_file => blk: {
                if (@intToPtr(?[*]const u8, submission.arguments[0])) |filename_ptr| {
                    const filename_len = submission.arguments[1];
                    if (filename_len == 0) return service.Error.empty_string;
                    break :blk .{ .filename = filename_ptr[0..filename_len] };
                } else {
                    return service.Error.null_string;
                }
            },
            .allocate_memory => blk: {
                const size = submission.arguments[0];
                const alignment = submission.arguments[1];
                if (size == 0) return service.Error.size_is_zero;
                if (alignment == 0) return service.Error.alignment_is_zero;
                break :blk .{ .size = size, .alignment = alignment };
            },
            .get_framebuffer => blk: {
                comptime assert(service.Parameters == void);
                break :blk {};
            },
            .receive_message => blk: {
                comptime assert(service.Parameters == void);
                break :blk {};
            },
            .send_message => blk: {
                if (submission.arguments[0] < lib.Message.count) {
                    const message_id = @intToEnum(lib.Message.ID, submission.arguments[0]);
                    const message_context = @intToPtr(?*anyopaque, submission.arguments[1]);
                    break :blk .{ .message = .{ .id = message_id, .context = message_context } };
                } else {
                    return service.Error.invalid_message_id;
                }
            },
            .create_plain_window => blk: {
                break :blk .{
                    .user_window = @intToPtr(*lib.Window, submission.arguments[0]),
                };
            },
        };
    }

    pub const Input = extern struct {
        const IDIntType = u16;
        id: IDIntType,
        options: Options,
        unused0: u8 = 0,
        unused1: u16 = 0,
        unused2: u16 = 0,

        comptime {
            assert(@sizeOf(Input) == @sizeOf(u64));
        }
    };

    pub const Arguments = [5]u64;

    comptime {
        assert(@sizeOf(Submission) == 6 * @sizeOf(u64));
    }
};

pub const Manager = struct {
    buffer: []u8,
    submission_queue: QueueDescriptor,
    completion_queue: QueueDescriptor,

    pub const QueueDescriptor = struct {
        head: u32,
        tail: u32,
        offset: u32,
    };
};

// TODO: develop on this idea
pub const Syscall = struct {
    id: ID,

    pub const count = enumCount(ID);
    pub const ID = enum(Submission.Input.IDIntType) {
        ask_syscall_manager = 0,
        flush_syscall_manager = 1,
    };

    pub const Result = extern struct {
        a: u64,
        b: u64,
    };
};

pub fn add_syscall_descriptor(syscall: Syscall, arr: []Syscall) void {
    _ = arr;
    _ = syscall;
}

pub const DefaultNonBlockingResult = void;
pub const DefaultNonBlockingError = error{};

pub const Service = struct {
    id: ID,
    Parameters: type,
    Result: type,
    Error: type,

    pub const ID = enum(Submission.Input.IDIntType) {
        thread_exit = 0,
        log = 1,
        read_file = 2,
        allocate_memory = 3,
        get_framebuffer = 4,
        receive_message = 5,
        send_message = 6,
        create_plain_window = 7,
    };
    pub const count = enumCount(ID);

    pub fn from_id(comptime id: ID) Service {
        return services[@enumToInt(id)];
    }

    pub fn ParametersType(comptime id: ID) type {
        return services[@enumToInt(id)].Parameters;
    }

    pub fn ResultType(comptime id: Service.ID, comptime execution_mode: ExecutionMode) type {
        return switch (execution_mode) {
            .blocking => services[@enumToInt(id)].Result,
            .non_blocking => DefaultNonBlockingResult,
        };
    }

    pub fn ErrorType(comptime id: Service.ID, comptime execution_mode: ExecutionMode) type {
        return switch (execution_mode) {
            .blocking => services[@enumToInt(id)].Error,
            .non_blocking => DefaultNonBlockingError,
        };
    }
};

pub fn add_service_descriptor(comptime service: Service, comptime arr: []Service) void {
    arr[@enumToInt(service.id)] = service;
}
