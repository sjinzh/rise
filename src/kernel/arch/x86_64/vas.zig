const std = @import("../../../common/std.zig");

const common = @import("common.zig");
const Bitflag = @import("../../../common/bitflag.zig").Bitflag;
const kernel = @import("../../kernel.zig");
const PhysicalAddress = @import("../../physical_address.zig");
const PhysicalAddressSpace = @import("../../physical_address_space.zig");
const registers = @import("registers.zig");
const Timer = @import("../../timer.zig");
const VirtualAddress = @import("../../virtual_address.zig");
const VirtualAddressSpace = @import("../../virtual_address_space.zig");
const VirtualMemoryRegion = @import("../../virtual_memory_region.zig");
const x86_64 = @import("common.zig");

const cr3 = registers.cr3;
const log = std.log.scoped(.VAS);
const MapError = VirtualAddressSpace.MapError;
const page_size = common.page_size;

const VAS = struct {
    cr3: u64 = 0,
};

const Indices = [std.enum_count(PageIndex)]u16;

pub fn new(virtual_address_space: *VirtualAddressSpace, physical_address_space: *PhysicalAddressSpace) void {
    const page_count = @divExact(@sizeOf(PML4Table), common.page_size);
    const cr3_physical_address = physical_address_space.allocate(page_count) orelse @panic("wtf");
    virtual_address_space.arch = VAS{
        .cr3 = cr3_physical_address.value,
    };

    std.zero(virtual_address_space.arch.get_pml4().to_higher_half_virtual_address().access([*]u8)[0 .. @sizeOf(PML4Table) / 2]);
    if (virtual_address_space.privilege_level == .kernel) {
        const pml4_table = virtual_address_space.arch.get_pml4().to_higher_half_virtual_address().access([*]volatile PML4Table)[@sizeOf(PML4Table) / 2 ..];
        const allocation_size = pml4_table.len * x86_64.page_size;

        const result = virtual_address_space.allocate_extended(allocation_size, null, .{ .write = true }, VirtualAddressSpace.AlreadyLocked.no) catch @panic("wtf");
        for (pml4_table) |*element| {
            fill_pml4e(element, result.physical_address, result.virtual_address);
        }
    }
}

const safe_map = true;
const time_map = false;

var map_timer_register = Timer.Register{};

pub fn log_map_timer_register() void {
    log.debug("Registered mappings without allocations: {}", .{map_timer_register.count});
    log.debug("Mean: {}", .{map_timer_register.get_integer_mean()});
}

fn fill_pml4e(pml4e: *volatile PML4E, pdp_physical_address: PhysicalAddress, pdp_virtual_address: VirtualAddress) void {
    var pdp = pdp_virtual_address.access(*PDPTable);
    pdp.* = std.zeroes(PDPTable);
    var pml4_entry = pml4e.*;
    pml4_entry.value.or_flag(.present);
    pml4_entry.value.or_flag(.read_write);
    pml4_entry.value.or_flag(.user);
    pml4_entry.value.bits = set_entry_in_address_bits(pml4_entry.value.bits, pdp_physical_address);
    pml4e.value = pml4_entry.value;
}

pub fn map(virtual_address_space: *VirtualAddressSpace, physical_address: PhysicalAddress, virtual_address: VirtualAddress, flags: VAS.MemoryFlags) MapError!void {
    var allocation_count: u64 = 0;

    if (time_map) {
        map_timer_register.register_start();
    }
    defer {
        if (time_map) {
            if (allocation_count == 0) {
                map_timer_register.register_end();
            }
        }
    }

    if (safe_map) {
        std.assert((PhysicalAddress{ .value = virtual_address_space.arch.cr3 }).is_valid());
        std.assert(std.is_aligned(virtual_address.value, common.page_size));
        std.assert(std.is_aligned(physical_address.value, common.page_size));
    }

    const indices = compute_indices(virtual_address);

    var pdp: *volatile PDPTable = undefined;
    {
        var pml4 = virtual_address_space.arch.get_pml4().to_higher_half_virtual_address().access(*PML4Table);
        var pml4_entry = &pml4[indices[@enumToInt(PageIndex.PML4)]];
        var pml4_entry_value = pml4_entry.value;

        if (pml4_entry_value.contains(.present)) {
            pdp = get_address_from_entry_bits(pml4_entry_value.bits).to_higher_half_virtual_address().access(@TypeOf(pdp));
        } else {
            defer allocation_count += 1;

            const pdp_allocation_result = virtual_address_space.allocate_extended(@sizeOf(PDPTable), null, .{ .write = true }, VirtualAddressSpace.AlreadyLocked.yes) catch @panic("unable to alloc pdp");
            fill_pml4e(pml4_entry, pdp_allocation_result.physical_address, pdp_allocation_result.virtual_address);
        }
    }

    var pd: *volatile PDTable = undefined;
    {
        var pdp_entry = &pdp[indices[@enumToInt(PageIndex.PDP)]];
        var pdp_entry_value = pdp_entry.value;

        if (pdp_entry_value.contains(.present)) {
            pd = get_address_from_entry_bits(pdp_entry_value.bits).to_higher_half_virtual_address().access(@TypeOf(pd));
        } else {
            defer allocation_count += 1;

            const pd_allocation_result = virtual_address_space.allocate_extended(@sizeOf(PDTable), null, .{ .write = true }, VirtualAddressSpace.AlreadyLocked.yes) catch @panic("unable to alloc pdp");
            //const pd_allocation = kernel.physical_address_space.allocate(@divExact(@sizeOf(PDTable), common.page_size)) orelse @panic("unable to alloc pd");
            pd = pd_allocation_result.virtual_address.access(@TypeOf(pd));
            pd.* = std.zeroes(PDTable);
            pdp_entry_value.or_flag(.present);
            pdp_entry_value.or_flag(.read_write);
            pdp_entry_value.or_flag(.user);
            pdp_entry_value.bits = set_entry_in_address_bits(pdp_entry_value.bits, pd_allocation_result.physical_address);
            pdp_entry.value = pdp_entry_value;
        }
    }

    var pt: *volatile PTable = undefined;
    {
        var pd_entry = &pd[indices[@enumToInt(PageIndex.PD)]];
        var pd_entry_value = pd_entry.value;

        if (pd_entry_value.contains(.present)) {
            pt = get_address_from_entry_bits(pd_entry_value.bits).to_higher_half_virtual_address().access(@TypeOf(pt));
        } else {
            defer allocation_count += 1;

            const pt_allocation_result = virtual_address_space.allocate_extended(@sizeOf(PTable), null, .{ .write = true }, VirtualAddressSpace.AlreadyLocked.yes) catch @panic("unable to alloc pdp");
            pt = pt_allocation_result.virtual_address.access(@TypeOf(pt));
            pt.* = std.zeroes(PTable);
            pd_entry_value.or_flag(.present);
            pd_entry_value.or_flag(.read_write);
            pd_entry_value.or_flag(.user);
            pd_entry_value.bits = set_entry_in_address_bits(pd_entry_value.bits, pt_allocation_result.physical_address);
            pd_entry.value = pd_entry_value;
        }
    }

    const pte_ptr = &pt[indices[@enumToInt(PageIndex.PT)]];
    if (pte_ptr.value.contains(.present)) @panic("here");
    if (pte_ptr.value.contains(.present)) return MapError.already_present;

    pte_ptr.* = blk: {
        var pte = PTE{
            .value = PTE.Flags.from_bits(flags.bits),
        };

        pte.value.or_flag(.present);
        pte.value.bits = set_entry_in_address_bits(pte.value.bits, physical_address);

        break :blk pte;
    };
}

pub inline fn switch_address_spaces_if_necessary(new_address_space: *VirtualAddressSpace) void {
    const current_cr3 = cr3.read_raw();
    if (current_cr3 != new_address_space.arch.cr3) {
        cr3.write_raw(new_address_space.arch.cr3);
    }
}

pub inline fn is_current(vas: VAS) bool {
    const current = cr3.read_raw();
    return current == vas.cr3;
}

pub inline fn bootstrapping() VAS {
    return VAS{
        .cr3 = cr3.read_raw(),
    };
}

pub fn get_pml4(vas: VAS) PhysicalAddress {
    return PhysicalAddress.new(vas.cr3);
}

pub fn map_kernel_address_space_higher_half(vas: *VAS, kernel_address_space: *VirtualAddressSpace) void {
    const cr3_physical_address = PhysicalAddress.new(vas.cr3);
    const cr3_kernel_virtual_address = cr3_physical_address.to_higher_half_virtual_address();
    // TODO: maybe user flag is not necessary?
    kernel_address_space.map(cr3_physical_address, cr3_kernel_virtual_address, 1, .{ .write = true, .user = true }) catch unreachable;
    const pml4 = cr3_kernel_virtual_address.access(*PML4Table);
    std.zero_slice(PML4E, pml4[0..0x100]);
    std.copy(PML4E, pml4[0x100..], PhysicalAddress.new(kernel_address_space.arch.cr3).access_higher_half(*PML4Table)[0x100..]);
    log.debug("USER CR3: 0x{x}", .{cr3_physical_address.value});
}

pub fn translate_address(address_space: *VAS, asked_virtual_address: VirtualAddress) ?PhysicalAddress {
    std.assert(asked_virtual_address.is_valid());
    const virtual_address = asked_virtual_address.aligned_backward(common.page_size);

    const indices = compute_indices(virtual_address);

    var pdp: *volatile PDPTable = undefined;
    {
        //log.debug("CR3: 0x{x}", .{address_space.cr3});
        var pml4 = address_space.get_pml4().to_higher_half_virtual_address().access(*PML4Table);
        const pml4_entry = &pml4[indices[@enumToInt(PageIndex.PML4)]];
        var pml4_entry_value = pml4_entry.value;

        if (!pml4_entry_value.contains(.present)) return null;
        //log.debug("PML4 present", .{});

        pdp = get_address_from_entry_bits(pml4_entry_value.bits).to_higher_half_virtual_address().access(@TypeOf(pdp));
    }

    var pd: *volatile PDTable = undefined;
    {
        var pdp_entry = &pdp[indices[@enumToInt(PageIndex.PDP)]];
        var pdp_entry_value = pdp_entry.value;

        if (!pdp_entry_value.contains(.present)) return null;
        //log.debug("PDP present", .{});

        pd = get_address_from_entry_bits(pdp_entry_value.bits).to_higher_half_virtual_address().access(@TypeOf(pd));
    }

    var pt: *volatile PTable = undefined;
    {
        var pd_entry = &pd[indices[@enumToInt(PageIndex.PD)]];
        var pd_entry_value = pd_entry.value;

        if (!pd_entry_value.contains(.present)) return null;
        //log.debug("PD present", .{});

        pt = get_address_from_entry_bits(pd_entry_value.bits).to_higher_half_virtual_address().access(@TypeOf(pt));
    }

    const pte = pt[indices[@enumToInt(PageIndex.PT)]];
    if (!pte.value.contains(.present)) return null;

    const base_physical_address = get_address_from_entry_bits(pte.value.bits);
    const offset = asked_virtual_address.value - virtual_address.value;
    if (offset != 0) @panic("Error translating address: offset not zero");

    return PhysicalAddress.new(base_physical_address.value + offset);
}

fn compute_indices(virtual_address: VirtualAddress) Indices {
    var indices: Indices = undefined;
    var va = virtual_address.value;
    va = va >> 12;
    indices[3] = @truncate(u9, va);
    va = va >> 9;
    indices[2] = @truncate(u9, va);
    va = va >> 9;
    indices[1] = @truncate(u9, va);
    va = va >> 9;
    indices[0] = @truncate(u9, va);

    return indices;
}

pub inline fn make_current(address_space: VAS) void {
    cr3.write_raw(address_space.cr3);
}

pub inline fn new_flags(general_flags: VirtualAddressSpace.Flags) MemoryFlags {
    var flags = MemoryFlags.empty();
    if (general_flags.write) flags.or_flag(.read_write);
    if (general_flags.user) flags.or_flag(.user);
    if (general_flags.cache_disable) flags.or_flag(.cache_disable);
    if (general_flags.accessed) flags.or_flag(.accessed);
    if (!general_flags.execute) flags.or_flag(.execute_disable);
    return flags;
}

// TODO:
pub const MemoryFlags = Bitflag(true, u64, enum(u6) {
    read_write = 1,
    user = 2,
    write_through = 3,
    cache_disable = 4,
    accessed = 5,
    dirty = 6,
    pat = 7, // must be 0
    global = 8,
    execute_disable = 63,
});

const address_mask: u64 = 0x0000_00ff_ffff_f000;
fn set_entry_in_address_bits(old_entry_value: u64, new_address: PhysicalAddress) u64 {
    if (safe_map) {
        std.assert(x86_64.max_physical_address_bit == 40);
        std.assert(std.is_aligned(new_address.value, common.page_size));
    }
    const address_masked = new_address.value & address_mask;
    const old_entry_value_masked = old_entry_value & ~address_masked;
    const result = address_masked | old_entry_value_masked;
    return result;
}

inline fn get_address_from_entry_bits(entry_bits: u64) PhysicalAddress {
    if (safe_map) {
        std.assert(common.max_physical_address_bit == 40);
    }
    const address = entry_bits & address_mask;
    if (safe_map) {
        std.assert(std.is_aligned(address, common.page_size));
    }

    return PhysicalAddress.new(address);
}

const PageIndex = enum(u3) {
    PML4 = 0,
    PDP = 1,
    PD = 2,
    PT = 3,
};

const PML4E = struct {
    value: Flags,

    const Flags = Bitflag(true, u64, enum(u6) {
        present = 0,
        read_write = 1,
        user = 2,
        page_level_write_through = 3,
        page_level_cache_disable = 4,
        accessed = 5,
        hlat_restart = 11,
        execute_disable = 63, // IA32_EFER.NXE must be 1
    });
};

const PDPTE = struct {
    value: Flags,

    const Flags = Bitflag(true, u64, enum(u6) {
        present = 0,
        read_write = 1,
        user = 2,
        page_level_write_through = 3,
        page_level_cache_disable = 4,
        accessed = 5,
        page_size = 7, // must be 0
        hlat_restart = 11,
        execute_disable = 63, // IA32_EFER.NXE must be 1
    });
};

const PDE = struct {
    value: Flags,

    const Flags = Bitflag(true, u64, enum(u6) {
        present = 0,
        read_write = 1,
        user = 2,
        page_level_write_through = 3,
        page_level_cache_disable = 4,
        accessed = 5,
        page_size = 7, // must be 0
        hlat_restart = 11,
        execute_disable = 63, // IA32_EFER.NXE must be 1
    });
};

const PTE = struct {
    value: Flags,

    const Flags = Bitflag(true, u64, enum(u6) {
        present = 0,
        read_write = 1,
        user = 2,
        page_level_write_through = 3,
        page_level_cache_disable = 4,
        accessed = 5,
        dirty = 6,
        pat = 7, // must be 0
        global = 8,
        hlat_restart = 11,
        // TODO: protection key
        execute_disable = 63, // IA32_EFER.NXE must be 1
    });
};

const PML4Table = [512]PML4E;
const PDPTable = [512]PDPTE;
const PDTable = [512]PDE;
const PTable = [512]PTE;
