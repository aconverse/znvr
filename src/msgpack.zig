const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

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

pub fn pack_fixarr(buf: *ArrayList(u8), vals: ValueIterator) !void {
    const len = vals.count();
    std.debug.assert(len <= 15);
    try pack_raw(buf, 0x90 | @as(u8, @truncate(len)));
    var v2 = vals;
    while (try v2.next()) |elem| {
        try pack_val(buf, elem);
    }
}

pub fn pack_arr32(buf: *ArrayList(u8), vals: ValueIterator) !void {
    const len = vals.count();
    std.debug.assert(len <= std.math.maxInt(u32));
    try pack_raw(buf, 0xdd);
    try pack_raw_be32(buf, @truncate(len));
    var v2 = vals;
    while (try v2.next()) |elem| {
        try pack_val(buf, elem);
    }
}

pub fn pack_arr(buf: *ArrayList(u8), vals: ValueIterator) !void {
    const len = vals.count();
    if (len <= 15) {
        return pack_fixarr(buf, vals);
    }
    return pack_arr32(buf, vals);
}

pub fn pack_arr_from_slice(buf: *ArrayList(u8), vals: []const Value) !void {
    const pi = PackIterator{ .slice = vals };
    return pack_arr(buf, ValueIterator{ .Pack = pi });
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

pub const Value = union(enum) {
    Nil: void,
    Int: i64,
    Str: []const u8,
    Arr: ValueIterator,

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
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Nil => {
                try writer.print("null", .{});
            },
            .Int => |v| {
                try writer.print("{}", .{v});
            },
            .Str => |s| {
                try writer.print("{s}", .{s});
            },
            .Arr => |vi| {
                try writer.print("[", .{});
                var vii = vi;
                var leader: []const u8 = "";
                while (try vii.next()) |v| {
                    try writer.print("{s}{}", .{ leader, v });
                    leader = ", ";
                }
                try writer.print("]", .{});
            },
        }
    }
};

const UnpackIterator = struct {
    count: usize,
    buf: []const u8,

    pub fn next(self: *UnpackIterator) !?Value {
        if (self.count == 0) {
            return null;
        }
        self.count -= 1;
        return try unpack_val(&self.buf);
    }
};

const PackIterator = struct {
    slice: []const Value,

    pub fn next(self: *PackIterator) !?Value {
        if (self.slice.len == 0) {
            return null;
        }
        const rv = self.slice[0];
        self.slice = self.slice[1..];
        return rv; //@as(?Value, rv);
    }
};

pub const ValueIterator = union(enum) {
    Unpack: UnpackIterator,
    Pack: PackIterator,

    pub fn next(self: *ValueIterator) !?Value {
        switch (self.*) {
            .Unpack => |*u| return u.next(),
            .Pack => |*p| return p.next(),
        }
    }
    pub fn count(self: ValueIterator) usize {
        switch (self) {
            .Unpack => |u| return u.count,
            .Pack => |p| return p.slice.len,
        }
    }
};

const PackError = error{
    // From allocator:
    OutOfMemory,
    // These happen when copying an unpack iterator:
    UnhandledCode,
    Eof,
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
            return pack_arr(buf, a);
        },
    }
}

const UnpackError = error{
    UnhandledCode,
    Eof,
};

pub fn unpack_val(buf: *[]const u8) UnpackError!Value {
    if (buf.*.len == 0) {
        return UnpackError.Eof;
    }
    const sig: u8 = buf.*[0];
    switch (sig) {
        0x00...0x7f => {
            buf.* = buf.*[1..];
            return Value{ .Int = sig };
        },
        0xa0...0xbf => {
            return Value{ .Str = try unpack_fixstr(buf) };
        },
        0x90...0x9f => {
            return Value{ .Arr = ValueIterator{ .Unpack = try unpack_fixarr(buf) } };
        },
        0xc0 => {
            buf.* = buf.*[1..];
            return Value.Nil;
        },
        0xd9 => {
            return Value{ .Str = try unpack_str8(buf) };
        },
        0xda => {
            return Value{ .Str = try unpack_str16(buf) };
        },
        else => {
            std.debug.print("unhandled code {x}\n", .{sig});
            return UnpackError.UnhandledCode;
        },
    }
}

fn unpack_fixstr(buf: *[]const u8) ![]const u8 {
    if (buf.*.len == 0) {
        return UnpackError.Eof;
    }
    const sig: u8 = buf.*[0];
    std.debug.assert(sig >= 0xa0 and sig <= 0xbf);
    buf.* = buf.*[1..];
    const len = sig & 0x1F;
    if (len > buf.*.len) {
        return UnpackError.Eof;
    }
    const val = buf.*[0..len];
    buf.* = buf.*[len..];
    return val;
}

fn unpack_fixarr(buf: *[]const u8) !UnpackIterator {
    if (buf.*.len == 0) {
        return UnpackError.Eof;
    }
    const sig: u8 = buf.*[0];
    std.debug.assert(sig >= 0x90 and sig <= 0x9f);
    buf.* = buf.*[1..];
    const len = sig & 0xF;
    if (len > buf.*.len) {
        return UnpackError.Eof;
    }
    var rv = UnpackIterator{ .count = len, .buf = buf.* };
    // Iterate over the full iterator (parsing recursively) to segment the buffer
    var it = rv;
    while (it.next() catch |e| {
        return e;
    }) |v| {
        _ = v;
    }

    rv.buf = rv.buf[0..(rv.buf.len - it.buf.len)];
    buf.* = it.buf;

    return rv;
}

fn unpack_str8(buf: *[]const u8) ![]const u8 {
    if (buf.*.len <= 1) {
        return UnpackError.Eof;
    }
    const sig: u8 = buf.*[0];
    std.debug.assert(sig == 0xd9);
    const len = buf.*[1];
    buf.* = buf.*[2..];
    if (len > buf.*.len) {
        return UnpackError.Eof;
    }
    const val = buf.*[0..len];
    buf.* = buf.*[len..];
    return val;
}

fn unpack_str16(buf: *[]const u8) ![]const u8 {
    if (buf.*.len <= 2) {
        return UnpackError.Eof;
    }
    const sig: u8 = buf.*[0];
    std.debug.assert(sig == 0xda);
    const len = (@as(usize, buf.*[1]) << 8) | (buf.*[2]);
    buf.* = buf.*[3..];
    if (len > buf.*.len) {
        return UnpackError.Eof;
    }
    const val = buf.*[0..len];
    buf.* = buf.*[len..];
    return val;
}

test "packing unpacking" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var buf = ArrayList(u8).init(alloc);
    defer buf.clearAndFree();

    try pack_int(&buf, 10);
    try pack_int(&buf, 126);
    try pack_int(&buf, 127);

    var unpack_sl = buf.items;
    try expect((try unpack_val(&unpack_sl)).Int == 10);
    try expect((try unpack_val(&unpack_sl)).Int == 126);
    try expect((try unpack_val(&unpack_sl)).Int == 127);

    const res = unpack_val(&unpack_sl);
    try std.testing.expectError(UnpackError.Eof, res);
}

test "unpack req" {
    const expect = std.testing.expect;

    const req = [_]u8{ 0x94, 0x0, 0x1, 0xac, 0x6e, 0x76, 0x69, 0x6d, 0x5f, 0x63, 0x6f, 0x6d, 0x6d, 0x61, 0x6e, 0x64, 0x91, 0xb4, 0x74, 0x61, 0x62, 0x20, 0x64, 0x72, 0x6f, 0x70, 0x20, 0x2e, 0x5c, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x7a, 0x69, 0x67 };

    var req_sl: []const u8 = req[1..];
    try expect((try unpack_val(&req_sl)).Int == 0);
    try expect((try unpack_val(&req_sl)).Int == 1);
    const cmd = try unpack_val(&req_sl);
    try expect(std.mem.eql(u8, cmd.Str, "nvim_command"));
    var arr_iter = (try unpack_val(&req_sl)).Arr;
    try expect(arr_iter.count() == 1);
    const inner = (try arr_iter.next()).?;
    try expect(std.mem.eql(u8, inner.Str, "tab drop .\\hello.zig"));

    try expect(req_sl.len == 0);
    const res = unpack_val(&req_sl);
    try std.testing.expectError(UnpackError.Eof, res);
}

test "unpack resp" {
    const expect = std.testing.expect;

    const resp = [_]u8{ 0x94, 0x1, 0x1, 0xc0, 0xc0 };

    var resp_sl: []const u8 = resp[1..];
    try expect((try unpack_val(&resp_sl)).Int == 1);
    try expect((try unpack_val(&resp_sl)).Int == 1);
    try expect((try unpack_val(&resp_sl)) == Value.Nil);
    try expect((try unpack_val(&resp_sl)) == Value.Nil);
    const res = unpack_val(&resp_sl);
    try std.testing.expectError(UnpackError.Eof, res);
}
