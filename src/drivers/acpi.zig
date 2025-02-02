const common = @import("common");
const assert = common.assert;
const string_eq = common.string_eq;
const log = common.log.scoped(.ACPI);

const rise = @import("rise");
const DeviceManager = rise.DeviceManager;
const panic = rise.panic;
const PhysicalAddress = rise.PhysicalAddress;
const TODO = rise.TODO;
const VirtualAddress = rise.VirtualAddress;
const VirtualAddressSpace = rise.VirtualAddressSpace;

const arch = @import("arch");
const interrupts = arch.interrupts;
const page_size = arch.page_size;
const x86_64 = arch.x86_64;

const Signature = enum(u32) {
    APIC = @ptrCast(*align(1) const u32, "APIC").*,
    FACP = @ptrCast(*align(1) const u32, "FACP").*,
    HPET = @ptrCast(*align(1) const u32, "HPET").*,
    MCFG = @ptrCast(*align(1) const u32, "MCFG").*,
    WAET = @ptrCast(*align(1) const u32, "WAET").*,
};

comptime {
    assert(common.cpu.arch == .x86_64);
}

inline fn map_a_page_to_higher_half_from_not_aligned_physical_address(virtual_address_space: *VirtualAddressSpace, physical_address: PhysicalAddress, comptime maybe_flags: ?VirtualAddressSpace.Flags) VirtualAddress {
    const aligned_physical_page = physical_address.aligned_backward(page_size);
    const aligned_virtual_page = aligned_physical_page.to_higher_half_virtual_address();
    virtual_address_space.map_reserved_region(aligned_physical_page, aligned_virtual_page, page_size, if (maybe_flags) |flags| flags else VirtualAddressSpace.Flags.empty());
    const virtual_address = physical_address.to_higher_half_virtual_address();
    return virtual_address;
}

fn is_in_page_range(a: u64, b: u64) bool {
    const difference = if (a > b) a - b else b - a;
    return difference < page_size;
}

/// ACPI initialization. We should have a page mapper ready before executing this function
pub fn init(device_manager: *DeviceManager, virtual_address_space: *VirtualAddressSpace) !void {
    _ = device_manager;
    const rsdp1 = map_a_page_to_higher_half_from_not_aligned_physical_address(virtual_address_space, @import("root").get_rsdp_physical_address(), null).access(*align(1) RSDP1);

    if (rsdp1.revision == 0) {
        log.debug("First version", .{});
        log.debug("RSDT: 0x{x}", .{rsdp1.RSDT_address});
        const rsdt = map_a_page_to_higher_half_from_not_aligned_physical_address(virtual_address_space, PhysicalAddress.new(rsdp1.RSDT_address), null).access(*align(1) Header);
        log.debug("RSDT length: {}", .{rsdt.length});
        const rsdt_table_count = (rsdt.length - @sizeOf(Header)) / @sizeOf(u32);
        log.debug("RSDT table count: {}", .{rsdt_table_count});
        const tables = @intToPtr([*]align(1) u32, @ptrToInt(rsdt) + @sizeOf(Header))[0..rsdt_table_count];
        var last_physical: u64 = rsdp1.RSDT_address;

        for (tables) |table_address| {
            log.debug("Table address: 0x{x}", .{table_address});
            const table_header = if (is_in_page_range(last_physical, table_address)) PhysicalAddress.new(table_address).to_higher_half_virtual_address().access(*align(1) Header) else map_a_page_to_higher_half_from_not_aligned_physical_address(virtual_address_space, PhysicalAddress.new(table_address), null).access(*align(1) Header);
            last_physical = table_address;

            switch (table_header.signature) {
                .APIC => {
                    const madt = @ptrCast(*align(1) MADT, table_header);
                    log.debug("MADT: {}", .{madt});
                    log.debug("LAPIC address: 0x{x}", .{madt.LAPIC_address});

                    const madt_top = @ptrToInt(madt) + madt.header.length;
                    var offset = @ptrToInt(madt) + @sizeOf(MADT);

                    var processor_count: u64 = 0;
                    var iso_count: u64 = 0;
                    var entry_length: u64 = 0;

                    while (offset != madt_top) : (offset += entry_length) {
                        const entry_type = @intToPtr(*MADT.Type, offset).*;
                        entry_length = @intToPtr(*u8, offset + 1).*;
                        processor_count += @boolToInt(entry_type == .LAPIC);
                        iso_count += @boolToInt(entry_type == .ISO);
                    }

                    interrupts.iso = virtual_address_space.heap.allocator.allocate_many(interrupts.ISO, iso_count) catch @panic("iso");
                    var iso_i: u64 = 0;

                    offset = @ptrToInt(madt) + @sizeOf(MADT);

                    while (offset != madt_top) : (offset += entry_length) {
                        const entry_type = @intToPtr(*MADT.Type, offset).*;
                        entry_length = @intToPtr(*u8, offset + 1).*;

                        switch (entry_type) {
                            .LAPIC => {
                                const lapic = @intToPtr(*align(1) MADT.LAPIC, offset);
                                log.debug("LAPIC: {}", .{lapic});
                                assert(@sizeOf(MADT.LAPIC) == entry_length);
                            },
                            .IO_APIC => {
                                const ioapic = @intToPtr(*align(1) MADT.IO_APIC, offset);
                                log.debug("IO_APIC: {}", .{ioapic});
                                assert(@sizeOf(MADT.IO_APIC) == entry_length);
                                interrupts.ioapic.gsi = ioapic.global_system_interrupt_base;
                                interrupts.ioapic.address = PhysicalAddress.new(ioapic.IO_APIC_address);
                                _ = map_a_page_to_higher_half_from_not_aligned_physical_address(virtual_address_space, interrupts.ioapic.address, .{ .write = true, .cache_disable = true });
                                interrupts.ioapic.id = ioapic.IO_APIC_ID;
                            },
                            .ISO => {
                                const iso = @intToPtr(*align(1) MADT.InterruptSourceOverride, offset);
                                log.debug("ISO: {}", .{iso});
                                assert(@sizeOf(MADT.InterruptSourceOverride) == entry_length);
                                const iso_ptr = &interrupts.iso[iso_i];
                                iso_i += 1;
                                iso_ptr.gsi = iso.global_system_interrupt;
                                iso_ptr.source_IRQ = iso.source;
                                iso_ptr.active_low = iso.flags & 2 != 0;
                                iso_ptr.level_triggered = iso.flags & 8 != 0;
                            },
                            .LAPIC_NMI => {
                                const lapic_nmi = @intToPtr(*align(1) MADT.LAPIC_NMI, offset);
                                log.debug("LAPIC_NMI: {}", .{lapic_nmi});
                                assert(@sizeOf(MADT.LAPIC_NMI) == entry_length);
                            },
                            else => panic("ni: {}", .{entry_type}),
                        }
                    }
                },
                else => {
                    log.debug("Ignored table: {s}", .{@tagName(table_header.signature)});
                },
            }
        }
    } else {
        assert(rsdp1.revision == 2);
        //const rsdp2 = @ptrCast(*RSDP2, rsdp1);
        log.debug("Second version", .{});
        TODO();
    }
}

const rsdt_signature = [4]u8{ 'R', 'S', 'D', 'T' };
pub fn check_valid_sdt(rsdt: *align(1) Header) void {
    log.debug("Header size: {}", .{@sizeOf(Header)});
    assert(@sizeOf(Header) == 36);
    if (rsdt.revision != 1) {
        @panic("bad revision");
    }
    if (!string_eq(&rsdt.signature, &rsdt_signature)) {
        @panic("bad signature");
    }
    if (rsdt.length >= 16384) {
        @panic("bad length");
    }
    if (checksum(@ptrCast([*]u8, rsdt)[0..rsdt.length]) != 0) {
        @panic("bad checksum");
    }
}

fn checksum(slice: []const u8) u8 {
    if (slice.len == 0) return 0;

    var total: u64 = 0;
    for (slice) |byte| {
        total += byte;
    }

    return @truncate(u8, total);
}

const RSDP1 = extern struct {
    signature: [8]u8,
    checksum: u8,
    OEM_ID: [6]u8,
    revision: u8,
    RSDT_address: u32,

    comptime {
        assert(@sizeOf(RSDP1) == 20);
    }
};

const RSDP2 = packed struct {
    rsdp1: RSDP1,
    length: u32,
    XSDT_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

const Header = extern struct {
    signature: Signature,
    length: u32,
    revision: u8,
    checksum: u8,
    OEM_ID: [6]u8,
    OEM_table_ID: [8]u8,
    OEM_revision: u32,
    creator_ID: u32,
    creator_revision: u32,
    comptime {
        assert(@sizeOf(Header) == 36);
    }
};

const MADT = extern struct {
    header: Header,
    LAPIC_address: u32,
    flags: u32,

    const Type = enum(u8) {
        LAPIC = 0,
        IO_APIC = 1,
        ISO = 2,
        NMI_source = 3,
        LAPIC_NMI = 4,
        LAPIC_address_override = 5,
        IO_SAPIC = 6,
        LSAPIC = 7,
        platform_interrupt_sources = 8,
        Lx2APIC = 9,
        Lx2APIC_NMI = 0xa,
        GIC_CPU_interface = 0xb,
        GIC_distributor = 0xc,
        GIC_MSI_frame = 0xd,
        GIC_redistributor = 0xe,
        GIC_interrupt_translation_service = 0xf,
    };

    const LAPIC = struct {
        type: Type,
        length: u8,
        ACPI_processor_UID: u8,
        APIC_ID: u8,
        flags: u32,

        comptime {
            assert(@sizeOf(@This()) == @sizeOf(u64));
        }
    };

    const IO_APIC = extern struct {
        type: Type,
        length: u8,
        IO_APIC_ID: u8,
        reserved: u8,
        IO_APIC_address: u32,
        global_system_interrupt_base: u32,

        comptime {
            assert(@sizeOf(@This()) == @sizeOf(u64) + @sizeOf(u32));
        }
    };

    const InterruptSourceOverride = extern struct {
        type: Type,
        length: u8,
        bus: u8,
        source: u8,
        global_system_interrupt: u32 align(2),
        flags: u16 align(2),

        comptime {
            assert(@sizeOf(@This()) == @sizeOf(u64) + @sizeOf(u16));
        }
    };

    const LAPIC_NMI = extern struct {
        type: Type,
        length: u8,
        ACPI_processor_UID: u8,
        flags: u16 align(1),
        LAPIC_lint: u8,

        comptime {
            assert(@sizeOf(@This()) == @sizeOf(u32) + @sizeOf(u16));
        }
    };
};

const MCFG = packed struct {
    header: Header,
    reserved: u64,

    fn get_configurations(mcfg: *align(1) MCFG) []Configuration {
        const entry_count = (mcfg.header.length - @sizeOf(MCFG)) / @sizeOf(Configuration);
        const configuration_base = @ptrToInt(mcfg) + @sizeOf(MCFG);
        return @intToPtr([*]Configuration, configuration_base)[0..entry_count];
    }

    comptime {
        assert(@sizeOf(MCFG) == @sizeOf(Header) + @sizeOf(u64));
        assert(@sizeOf(Configuration) == 0x10);
    }

    const Configuration = packed struct {
        base_address: u64,
        segment_group_number: u16,
        start_bus: u8,
        end_bus: u8,
        reserved: u32,
    };
};
