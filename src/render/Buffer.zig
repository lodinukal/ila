const Buffer = @This();

const std = @import("std");

const ila = @import("../root.zig");
const Context = ila.render.Context;

allocator: std.mem.Allocator,
buffer: ?*ila.gpu.Buffer,

cbv: ?*ila.gpu.Resource,
srv: ?*ila.gpu.Resource,
uav: ?*ila.gpu.Resource,

desc: ila.gpu.BufferDesc,
len: u64,
/// used for host mapped buffers, null if not mapped
mapped: ?[]u8 = null,

pub const MappingMode = enum {
    always_map,
    map_when_needed,
};

pub fn initCapacity(allocator: std.mem.Allocator, desc: ila.gpu.BufferDesc, mode: MappingMode) !Buffer {
    var self: Buffer = .{
        .allocator = allocator,
        .buffer = null,
        .cbv = null,
        .srv = null,
        .uav = null,
        .desc = desc,
        .len = 0,
    };
    self.desc.size = 0;
    try self.resize(desc.size, mode);
    return self;
}

pub fn deinit(self: *Buffer) void {
    if (self.mapped) |_| {
        self.buffer.?.unmap();
    }

    if (self.cbv) |cbv| cbv.deinit();
    if (self.srv) |srv| srv.deinit();
    if (self.uav) |uav| uav.deinit();
    if (self.buffer) |buf| buf.deinit();
    self.buffer = null;
    self.cbv = null;
    self.srv = null;
    self.uav = null;
    self.len = 0;
}

pub fn unusedCapacity(self: Buffer) u64 {
    return self.desc.size - self.len;
}

pub fn resize(self: *Buffer, new_size: u64, mode: MappingMode) !void {
    if (new_size == self.desc.size) return;

    const old_size = self.desc.size;
    self.desc.size = new_size;
    errdefer self.desc.size = old_size;

    const new_buffer = try ila.gpu.Buffer.init(self.allocator, self.desc);
    if (self.buffer) |old_buffer| {
        _ = old_buffer;
        // TODO: copy over data using transfer queue
    }
    const old_len = self.len;
    self.deinit();
    self.len = old_len;
    self.buffer = new_buffer;
    if (mode == .always_map) {
        if (self.desc.location != .host_upload) {
            std.log.err("Buffer.resize called with always_map but location is not host_upload", .{});
        } else self.mapped = try self.buffer.?.map(.whole);
    }
    const format: ila.gpu.Format = if (self.desc.structure_stride > 0) .unknown else .R32UI;
    if (self.desc.usage.cbv) {
        self.cbv = try .initBuffer(self.allocator, .{
            .name = "Buffer-cbv",
            .buffer = self.buffer.?,
            .format = format,
            .kind = .cbv,
        });
    }
    if (self.desc.usage.srv) {
        self.srv = try .initBuffer(self.allocator, .{
            .name = "Buffer-srv",
            .buffer = self.buffer.?,
            .format = format,
            .kind = .srv,
        });
    }
    if (self.desc.usage.uav) {
        self.uav = try .initBuffer(self.allocator, .{
            .name = "Buffer-uav",
            .buffer = self.buffer.?,
            .format = format,
            .kind = .uav,
        });
    }
}

pub const AppendDesc = struct {
    context: *Context,
    data: []const u8,
    after: ila.gpu.BufferState,
    /// whether this will wait for the GPU to finish before continuing
    blocks: bool = false,
};

pub fn append(self: *Buffer, desc: AppendDesc) !void {
    const new_size = self.len + desc.data.len;
    if (new_size > self.desc.size) {
        return error.BufferTooSmall;
    }
    self.appendAssumeCapacity(desc);
}

pub fn appendAssumeCapacity(self: *Buffer, desc: AppendDesc) void {
    const old_len = self.len;
    self.setSlice(.{
        .context = desc.context,
        .offset = old_len,
        .data = desc.data,
        .after = desc.after,
        .blocks = desc.blocks,
    }) catch |err| {
        std.debug.panic("Failed to append assumed to Buffer: {s}", .{@errorName(err)});
    };
    self.len += desc.data.len;
}

pub const SetDesc = struct {
    context: *Context,
    offset: u64 = 0,
    data: []const u8,
    after: ila.gpu.BufferState,
    /// whether this will wait for the GPU to finish before continuing
    blocks: bool = false,
};

pub fn setSlice(self: *Buffer, desc: SetDesc) !void {
    if (self.desc.location == .device) {
        var eph_buffer: Buffer = try desc.context.acquireTransferBuffer(desc.data.len);
        defer desc.context.releaseTransferBuffer(eph_buffer);

        const buffer_len_before = eph_buffer.len;
        eph_buffer.appendAssumeCapacity(.{
            .context = desc.context,
            .data = desc.data,
            .after = desc.after,
            // shouldnt block here
            // .blocks = desc.blocks,
            .blocks = false,
        });

        const cmd: *ila.gpu.CommandBuffer = try desc.context.transferCommandBuffer();
        cmd.ensureBufferState(self.buffer.?, .copy_dest);
        cmd.copyBufferToBuffer(
            self.buffer.?,
            desc.offset,
            eph_buffer.buffer.?,
            buffer_len_before,
            desc.data.len,
        );
        cmd.ensureBufferState(self.buffer.?, desc.after);

        const wait = try desc.context.flushTransfer();
        if (desc.blocks) {
            try desc.context.waitTransfer(wait);
        }

        return;
    }
    // is memory mapped
    std.debug.assert(desc.offset + desc.data.len <= self.desc.size);
    const mapped = try self.map(.offsetSize(desc.offset, desc.data.len));
    defer self.unmap();
    @memcpy(mapped, desc.data);
}

pub fn map(self: *Buffer, range: ila.gpu.Buffer.Range) ![]u8 {
    const buffer = self.buffer orelse return error.NoBuffer;
    const real_size = range.realSize(buffer);
    std.debug.assert(range.offset + real_size <= self.desc.size);
    if (self.mapped) |bytes| {
        return bytes[range.offset..][0..real_size];
    }

    std.debug.assert(self.desc.location == .host_upload or self.desc.location == .host_readback);
    const mapped = try buffer.map(range);
    return mapped;
}

pub fn mapSlice(self: *Buffer, comptime T: type, range: ila.gpu.Buffer.Range) ![]align(1) T {
    const real_size = range.realSize(self.buffer orelse return error.NoBuffer);
    std.debug.assert(real_size % @sizeOf(T) == 0);
    const mapped = try self.map(range);
    return std.mem.bytesAsSlice(T, mapped);
}

pub fn unmap(self: *Buffer) void {
    if (self.mapped) |_| {
        return;
    }
    if (self.buffer) |buf| {
        buf.unmap();
    }
}
