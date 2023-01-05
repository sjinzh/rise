const lib = @import("lib");
const privileged = @import("privileged");
const assert = lib.assert;
const log = lib.log.scoped(.BIOS);

var buffer = [1]u8{0} ** (0x200 * 0x20);

inline fn segment(value: u32) u16 {
    return @intCast(u16, value & 0xffff0) >> 4;
}

inline fn offset(value: u32) u16 {
    return @truncate(u16, value & 0xf >> 0);
}

pub const Disk = extern struct {
    disk: lib.Disk,

    pub fn read(disk: *lib.Disk, sector_count: u64, sector_offset: u64, provided_buffer: ?[]const u8) lib.Disk.ReadError!lib.Disk.ReadResult {
        assert(provided_buffer != null);
        _ = disk;
        if (sector_count > lib.maxInt(u16)) @panic("too many sectors");

        const buffer_address = @ptrToInt(&buffer);
        if (buffer_address > lib.maxInt(u16)) @panic("address too high");

        const dap = DAP{
            .sector_count = @intCast(u16, sector_count),
            .offset = @intCast(u16, buffer_address),
            .segment = 0,
            .lba = sector_offset,
        };

        const dap_address = @ptrToInt(&dap);
        const dap_offset = offset(dap_address);
        const dap_segment = segment(dap_address);

        var registers = Registers{
            .eax = 0x4200,
            .edx = 0x80,
            .esi = dap_offset,
            .ds = dap_segment,
        };

        int(0x13, &registers, &registers);
        if (registers.eflags & 1 != 0) @panic("disk read failed");
        log.debug("buffer[0]: 0x{x}", .{buffer[0]});
        @panic("todo: disk read");
    }

    pub fn write(disk: *lib.Disk, bytes: []const u8, sector_offset: u64, commit_memory_to_disk: bool) lib.Disk.WriteError!void {
        _ = disk;
        _ = bytes;
        _ = sector_offset;
        _ = commit_memory_to_disk;
        @panic("todo: disk write");
    }
};

extern fn int(number: u8, out_regs: *Registers, in_regs: *const Registers) callconv(.C) void;

const DAP = lib.PartitionTable.MBR.DAP;

extern fn hang() callconv(.C) noreturn;

const Registers = extern struct {
    gs: u16 = 0,
    fs: u16 = 0,
    es: u16 = 0,
    ds: u16 = 0,
    eflags: u32 = 0,
    ebp: u32 = 0,
    edi: u32 = 0,
    esi: u32 = 0,
    edx: u32 = 0,
    ecx: u32 = 0,
    ebx: u32 = 0,
    eax: u32 = 0,
};

fn is_a20_enabled() bool {
    const address = 0x7dfe;
    const address_with_offset = address + 0x100000;
    if (@intToPtr(*volatile u16, address).* != @intToPtr(*volatile u16, address_with_offset).*) {
        return true;
    }

    @intToPtr(*volatile u16, address).* = ~(@intToPtr(*volatile u16, address).*);

    if (@intToPtr(*volatile u16, address).* != @intToPtr(*volatile u16, address_with_offset).*) {
        return true;
    }

    return false;
}

const A20Error = error{a20_not_enabled};

pub fn a20_enable() A20Error!void {
    log.debug("Trying to enable A20", .{});
    if (!is_a20_enabled()) {
        return A20Error.a20_not_enabled;
    }
}

const MemoryMapEntry = extern struct {
    base: u64,
    len: u64,
    type: Type,
    unused: u32 = 0,

    const Type = enum(u32) {
        usable = 1,
        reserved = 2,
        acpi_reclaimable = 3,
        acpi_nvs = 4,
        bad_memory = 5,
    };
};

var memory_map_entries: [max_memory_entry_count]MemoryMapEntry = undefined;
var memory_map_entry_count: usize = 0;
const max_memory_entry_count = 256;

pub fn e820_init() ![]MemoryMapEntry {
    var registers = Registers{};

    for (memory_map_entries) |*entry, entry_index| {
        var memory_entry: MemoryMapEntry = undefined;
        registers.eax = 0xe820;
        registers.ecx = 24;
        registers.edx = 0x534d4150;
        registers.edi = @ptrToInt(&memory_entry);

        int(0x15, &registers, &registers);

        if (registers.eflags & 1 == 1) {
            memory_map_entry_count = entry_index;
            return memory_map_entries[0..memory_map_entry_count];
        }

        entry.* = memory_entry;

        if (registers.ebx == 0) {
            memory_map_entry_count = entry_index + 1;
            return memory_map_entries[0..memory_map_entry_count];
        }
    }

    @panic("Memory map entry count");
}
