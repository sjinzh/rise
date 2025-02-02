const lib = @import("lib");
const assert = lib.assert;

pub const Descriptor = extern struct {
    low: Low,
    base_high: u32,
    reserved: u32 = 0,

    comptime {
        assert(@sizeOf(Descriptor) == 16);
    }

    const Low = packed struct(u64) {
        limit_low: u16,
        base_low: u16,
        base_low_mid: u8,
        type: u4,
        unused0: u1 = 0,
        descriptor_privilege_level: u2,
        present: u1,
        limit_high: u4,
        available_for_system_software: u1,
        unused1: u2 = 0,
        granularity: u1,
        base_mid: u8,
    };
};

pub const Struct = extern struct {
    reserved0: u32 = 0,
    rsp: [3]u64 align(4) = [3]u64{ 0, 0, 0 },
    reserved1: u64 align(4) = 0,
    IST: [7]u64 align(4) = [7]u64{ 0, 0, 0, 0, 0, 0, 0 },
    reserved3: u64 align(4) = 0,
    reserved4: u16 = 0,
    IO_map_base_address: u16 = 104,

    comptime {
        assert(@sizeOf(Struct) == 104);
    }

    pub fn get_descriptor(tss: *const Struct, offset: u64) callconv(.SysV) Descriptor {
        const address = @ptrToInt(tss) + offset;
        return Descriptor{
            .low = .{
                .limit_low = @truncate(u16, @sizeOf(Struct) - 1),
                .base_low = @truncate(u16, address),
                .base_low_mid = @truncate(u8, address >> 16),
                .type = 0b1001,
                .descriptor_privilege_level = 0,
                .present = 1,
                .limit_high = 0,
                .available_for_system_software = 0,
                .granularity = 0,
                .base_mid = @truncate(u8, address >> 24),
            },
            .base_high = @truncate(u32, address >> 32),
        };
    }
};

pub const Entry = struct {
    low: u32,
    high: u32,
};
