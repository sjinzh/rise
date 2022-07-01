const kernel = @import("root");
const common = @import("../common.zig");

const current_arch = common.cpu.arch;
const arch = switch (current_arch) {
    .riscv64 => riscv64,
    .x86_64 => x86_64,
    else => @compileError("CPU architecture not supported"),
};

pub const riscv64 = @import("arch/riscv64.zig");
pub const x86_64 = @import("arch/x86_64.zig");

/// Arch-specific part of the address space
pub const AddressSpace = arch.AddressSpace;
pub const Spinlock = arch.Spinlock;
pub const CPU = arch.CPU;
pub const Context = arch.Context;
pub const Syscall = arch.Syscall;

pub const enable_interrupts = arch.enable_interrupts;
pub const disable_interrupts = arch.disable_interrupts;
pub const are_interrupts_enabled = arch.are_interrupts_enabled;

pub const pci_read_config = arch.pci_read_config;
pub const pci_write_config = arch.pci_write_config;

pub const io_read = arch.io_read;
pub const io_write = arch.io_write;

pub const get_current_cpu = arch.get_current_cpu;
pub const set_current_cpu = arch.set_current_cpu;

pub const next_timer = arch.next_timer;
pub const read_timestamp = arch.read_timestamp;

pub const get_memory_map = arch.get_memory_map;

pub const CPUFeatures = arch.CPUFeatures;

pub const init_block_drivers = arch.init_block_drivers;
pub const init_graphics_drivers = arch.init_graphics_drivers;

pub const Writer = struct {
    pub const Error = error{};
    pub var lock: arch.Spinlock = undefined;
    pub fn write(_: void, bytes: []const u8) Error!usize {
        return arch.writer_function(bytes);
    }
};

pub var writer = common.Writer(void, Writer.Error, Writer.write){ .context = {} };

pub const LocalStorage = struct {
    local_storage: *LocalStorage,
    cpu: *arch.CPU,
};

pub const set_local_storage = arch.set_local_storage;

pub fn check_page_size(asked_page_size: u64) u64 {
    for (arch.valid_page_sizes) |valid_page_size| {
        if (asked_page_size == valid_page_size) return asked_page_size;
    }

    unreachable;
}

pub const bootstrap_stack_size = 0x10000;

pub extern fn switch_context(context: *Context, new_address_space: *common.VirtualAddressSpace, kernel_stack: u64, new_thread: *common.Thread, old_address_space: *common.VirtualAddressSpace) callconv(.C) noreturn;