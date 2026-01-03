const std = @import("std");
const base = @import("base.zig");
const ArrayList = base.ArrayList;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub fn pack_raw(buf: *ArrayList(u8), val: u8) !void {
    try buf.append(val);
}

pub fn pack_raw_be32(buf: *ArrayList(u8), val: u32) !void {
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, val, .big);
    return pack_raw_slice(buf, &scratch);
}

pub fn pack_raw_be16(buf: *ArrayList(u8), val: u16) !void {
    var scratch: [2]u8 = undefined;
    std.mem.writeInt(u16, &scratch, val, .big);
    return pack_raw_slice(buf, &scratch);
}

pub fn pack_nil(buf: *ArrayList(u8)) !void {
    try pack_raw(buf, 0xc0);
}

pub fn pack_bool(buf: *ArrayList(u8), val: bool) !void {
    try pack_raw(buf, 0xc2 + @as(u8, @intFromBool(val)));
}

pub fn pack_int(buf: *ArrayList(u8), val: i64) !void {
    if (val >= MIN_FIXINT and val <= MAX_FIXINT) {
        return pack_fixint(buf, @truncate(val));
    }
    try buf.append(0xc0);
}

const MIN_FIXINT: i8 = @bitCast(@as(u8, 0b1110_0000));
const MAX_FIXINT: i8 = @bitCast(@as(u8, 0b0111_1111));
const MAX_FIXSTR: usize = 31;

pub fn pack_fixint(buf: *ArrayList(u8), val: i8) !void {
    std.debug.assert(val >= MIN_FIXINT);
    try pack_raw(buf, @bitCast(val));
}

pub fn pack_raw_slice(buf: *ArrayList(u8), vals: []const u8) !void {
    try buf.appendSlice(vals);
}

pub fn pack_fixstr(buf: *ArrayList(u8), vals: []const u8) !void {
    const len = vals.len;
    std.debug.assert(len <= MAX_FIXSTR);
    try pack_raw(buf, 0b10100000 | @as(u8, @truncate(len)));
    try pack_raw_slice(buf, vals);
}

pub fn pack_str16(buf: *ArrayList(u8), vals: []const u8) !void {
    const len = vals.len;
    std.debug.assert(len <= std.math.maxInt(u16));
    try pack_raw(buf, 0xda);
    try pack_raw_be16(buf, @truncate(len));
    try pack_raw_slice(buf, vals);
}

pub fn pack_str32(buf: *ArrayList(u8), vals: []const u8) !void {
    const len = vals.len;
    std.debug.assert(len <= std.math.maxInt(u32));
    try pack_raw(buf, 0xdb);
    try pack_raw_be32(buf, @truncate(len));
    try pack_raw_slice(buf, vals);
}

pub fn pack_fixarr(buf: *ArrayList(u8), vals: []const Value) !void {
    const len = vals.len;
    std.debug.assert(len <= 15);
    try pack_raw(buf, 0x90 | @as(u8, @truncate(len)));
    for (vals) |elem| {
        try pack_val(buf, elem);
    }
}

pub fn pack_arr32(buf: *ArrayList(u8), vals: []const Value) !void {
    const len = vals.len;
    std.debug.assert(len <= std.math.maxInt(u32));
    try pack_raw(buf, 0xdd);
    try pack_raw_be32(buf, @truncate(len));
    for (vals) |elem| {
        try pack_val(buf, elem);
    }
}

pub fn pack_arr(buf: *ArrayList(u8), vals: []const Value) !void {
    const len = vals.len;
    if (len <= 15) {
        return pack_fixarr(buf, vals);
    }
    return pack_arr32(buf, vals);
}

pub fn pack_str(buf: *ArrayList(u8), vals: []const u8) !void {
    if (vals.len <= MAX_FIXSTR) {
        return pack_fixstr(buf, vals);
    }
    if (vals.len <= std.math.maxInt(u16)) {
        return pack_str16(buf, vals);
    }
    return pack_str32(buf, vals);
}

pub fn pack_request_header(buf: *ArrayList(u8), msgId: i64) !void {
    try pack_raw(buf, 0x94);
    try pack_raw(buf, 0);
    try pack_int(buf, msgId);
}

pub const ValueArray = std.array_list.Aligned(Value, null);

fn value_array_deinit(alloc: Allocator, arr: *ValueArray) void {
    for (arr.items) |*elem| {
        elem.deinit(alloc);
    }
    arr.deinit(alloc);
}

pub const Value = union(enum) {
    Nil: void,
    Int: i64,
    Str: []const u8,
    Arr: ValueArray,

    pub fn is_nil(self: *const Value) bool {
        return self.* == Value.Nil;
    }
    pub fn is_int(self: *const Value) bool {
        switch (self.*) {
            .Int => {
                return true;
            },
            else => {
                return false;
            },
        }
    }
    pub fn get_int(self: *const Value) ?i64 {
        switch (self.*) {
            .Int => |v| {
                return v;
            },
            else => {
                return null;
            },
        }
    }
    pub fn format(
        self: @This(),
        writer: anytype,
    ) !void {
        switch (self) {
            .Nil => {
                try writer.print("null", .{});
            },
            .Int => |v| {
                try writer.print("{d}", .{v});
            },
            .Str => |s| {
                try writer.print("{s}", .{s});
            },
            .Arr => |va| {
                try writer.print("[", .{});
                var leader: []const u8 = "";
                for (va.items) |v| {
                    try writer.print("{s}{f}", .{ leader, v });
                    leader = ", ";
                }
                try writer.print("]", .{});
            },
        }
    }
    pub fn deinit(self: *Value, alloc: Allocator) void {
        switch (self.*) {
            .Nil => {},
            .Int => {},
            .Str => |*s| {
                alloc.free(s.*);
            },
            .Arr => |*arr| {
                value_array_deinit(alloc, arr);
            },
        }
        self.* = undefined;
    }
};

const PackError = error{
    OutOfMemory,
};

pub fn pack_val(buf: *ArrayList(u8), val: Value) PackError!void {
    switch (val) {
        .Nil => {
            return pack_nil(buf);
        },
        .Int => |i| {
            return pack_int(buf, i);
        },
        .Str => |s| {
            return pack_str(buf, s);
        },
        .Arr => |a| {
            return pack_arr(buf, a.items);
        },
    }
}

const UnpackError = error{
    UnhandledCode,
    OutOfMemory,
} || Reader.Error;

pub fn unpack_val(alloc: Allocator, r: *Reader) UnpackError!Value {
    const sig: u8 = try r.peekByte();
    switch (sig) {
        0x00...0x7f => {
            r.toss(1);
            return Value{ .Int = sig };
        },
        0xa0...0xbf => {
            return Value{ .Str = try unpack_fixstr(alloc, r) };
        },
        0x90...0x9f => {
            return Value{ .Arr = try unpack_fixarr(alloc, r) };
        },
        0xc0 => {
            r.toss(1);
            return Value.Nil;
        },
        0xd9 => {
            return Value{ .Str = try unpack_str8(alloc, r) };
        },
        0xda => {
            return Value{ .Str = try unpack_str16(alloc, r) };
        },
        else => {
            std.debug.print("unhandled code {x}\n", .{sig});
            return UnpackError.UnhandledCode;
        },
    }
}

fn unpack_fixstr(alloc: Allocator, r: *Reader) ![]const u8 {
    const sig: u8 = try r.takeByte();
    std.debug.assert(sig >= 0xa0 and sig <= 0xbf);
    const len = sig & 0x1F;
    const val = try alloc.alloc(u8, len);
    try r.readSliceAll(val);
    return val;
}

fn unpack_fixarr(alloc: Allocator, r: *Reader) !ValueArray {
    const sig: u8 = try r.takeByte();
    std.debug.assert(sig >= 0x90 and sig <= 0x9f);
    const len = sig & 0xF;
    var arr = try ValueArray.initCapacity(alloc, len);
    errdefer value_array_deinit(alloc, &arr);
    for (0..len) |_| {
        const v = try unpack_val(alloc, r);
        arr.append(alloc, v) catch unreachable;
    }
    return arr;
}

fn unpack_str8(alloc: Allocator, r: *Reader) ![]const u8 {
    const sig: u8 = try r.takeByte();
    std.debug.assert(sig == 0xd9);
    const len = try r.takeByte();
    const val = try alloc.alloc(u8, len);
    try r.readSliceAll(val);
    return val;
}

fn unpack_str16(alloc: Allocator, r: *Reader) ![]const u8 {
    const sig: u8 = try r.takeByte();
    std.debug.assert(sig == 0xda);
    const len = try r.takeInt(u16, std.builtin.Endian.big);
    const val = try alloc.alloc(u8, len);
    try r.readSliceAll(val);
    return val;
}

test "packing unpacking" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var buf = ArrayList(u8).init(alloc);
    defer buf.deinit();

    try pack_int(&buf, 10);
    try pack_int(&buf, 126);
    try pack_int(&buf, 127);

    var unpack_sl = Reader.fixed(buf.items);
    try expect((try unpack_val(alloc, &unpack_sl)).Int == 10);
    try expect((try unpack_val(alloc, &unpack_sl)).Int == 126);
    try expect((try unpack_val(alloc, &unpack_sl)).Int == 127);

    const res = unpack_val(alloc, &unpack_sl);
    try std.testing.expectError(UnpackError.EndOfStream, res);
}

test "unpack req" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    const req = [_]u8{ 0x94, 0x0, 0x1, 0xac, 0x6e, 0x76, 0x69, 0x6d, 0x5f, 0x63, 0x6f, 0x6d, 0x6d, 0x61, 0x6e, 0x64, 0x91, 0xb4, 0x74, 0x61, 0x62, 0x20, 0x64, 0x72, 0x6f, 0x70, 0x20, 0x2e, 0x5c, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x7a, 0x69, 0x67 };

    var req_sl = Reader.fixed(&req);
    var val = try unpack_val(alloc, &req_sl);
    defer val.deinit(alloc);
    try expect(val.Arr.items.len == 4);
    try expect(val.Arr.items[0].Int == 0);
    try expect(val.Arr.items[1].Int == 1);
    try expect(std.mem.eql(u8, val.Arr.items[2].Str, "nvim_command"));
    try expect(val.Arr.items[3].Arr.items.len == 1);
    try expect(std.mem.eql(u8, val.Arr.items[3].Arr.items[0].Str, "tab drop .\\hello.zig"));

    const res = unpack_val(alloc, &req_sl);
    try std.testing.expectError(UnpackError.EndOfStream, res);
}

test "unpack resp" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    const resp = [_]u8{ 0x94, 0x1, 0x1, 0xc0, 0xc0 };

    var resp_sl = Reader.fixed(&resp);
    var val = try unpack_val(alloc, &resp_sl);
    defer val.deinit(alloc);
    try expect(val.Arr.items.len == 4);
    try expect(val.Arr.items[0].Int == 1);
    try expect(val.Arr.items[1].Int == 1);
    try expect(val.Arr.items[2] == Value.Nil);
    try expect(val.Arr.items[3] == Value.Nil);
    const res = unpack_val(alloc, &resp_sl);
    try std.testing.expectError(UnpackError.EndOfStream, res);
}
