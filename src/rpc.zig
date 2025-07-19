const builtin = @import("builtin");
const std = @import("std");
const fs = std.fs;
//const io = std.io;
const mem = std.mem;
const net = std.net;
//const os = std.os;
const posix = std.posix;
const msgpack = @import("msgpack.zig");
const pipes = @import("pipes.zig");

const openScript = @embedFile("openfiles.lua");

pub const RpcConn = struct {
    msgId: u32,
    tp: Transport,

    pub fn openConn(addrBuf: []const u8) !RpcConn {
        if (builtin.os.tag == .windows and mem.startsWith(u8, addrBuf, "\\\\.\\pipe\\")) {
            const file = try pipes.connectNamedPipe(addrBuf);
            const rc = RpcConn{
                .msgId = 0,
                .tp = Transport{ .win_pipe = file },
            };
            return rc;
        }
        if (mem.indexOfAny(u8, addrBuf, "/\\") != null) {
            const stream = try net.connectUnixSocket(addrBuf);
            const rc = RpcConn{
                .msgId = 0,
                .tp = Transport{ .net_stream = stream },
            };
            return rc;
        }
        const hp = try splitHostPort(addrBuf);
        const addr = try net.Address.parseIp(hp.host, hp.port);
        const stream = try net.tcpConnectToAddress(addr);
        const rc = RpcConn{
            .msgId = 0,
            .tp = Transport{ .net_stream = stream },
        };
        return rc;
    }
    pub fn close(self: *RpcConn) void {
        self.tp.close();
    }

    pub fn sendCmd(self: *RpcConn, alloc: mem.Allocator, cmd: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_command");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, cmd);

        try self.tp.writeAll(buf.items);
    }

    pub fn sendExpr(self: *RpcConn, alloc: mem.Allocator, expr: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_eval");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, expr);

        try self.tp.writeAll(buf.items);
    }

    pub fn sendLuaOpen(self: *RpcConn, alloc: mem.Allocator, tabs: bool, dir: []const u8, files: []const [:0]u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        const values = try alloc.alloc(msgpack.Value, files.len);
        for (files, values) |file, *value| {
            value.* = .{ .Str = file };
        }
        defer alloc.free(values);

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_exec_lua");
        try msgpack.pack_raw(&buf, 0x92);
        try msgpack.pack_str(&buf, openScript);
        try msgpack.pack_raw(&buf, 0x93);
        try msgpack.pack_bool(&buf, tabs);
        try msgpack.pack_str(&buf, dir);
        try msgpack.pack_arr_from_slice(&buf, values);

        try self.tp.writeAll(buf.items);
    }

    pub fn sendChangeDir(self: *RpcConn, alloc: mem.Allocator, dir: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        // This might be overkill, but I think it handles escaping
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_exec_lua");
        try msgpack.pack_raw(&buf, 0x92);
        // Maybe parse the error lua side?
        try msgpack.pack_str(&buf, "vim.fn.chdir(...); return vim.fn.getcwd()");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, dir);

        try self.tp.writeAll(buf.items);
    }

    pub fn sendKeys(self: *RpcConn, alloc: mem.Allocator, cmd: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_input");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, cmd);

        try self.tp.writeAll(buf.items);
    }

    pub fn accumResp(self: *RpcConn, buf: *std.ArrayList(u8)) !?msgpack.Value {
        const startIdx = buf.items.len;
        var writePtr = startIdx;

        try buf.resize(writePtr + 1024);
        const count = self.tp.read(buf.items[writePtr..]) catch |err| {
            try buf.resize(writePtr);
            return err;
        };
        writePtr += count;
        try buf.resize(writePtr);

        var decode_buf: []const u8 = buf.items;
        const val = msgpack.unpack_val(&decode_buf) catch |err| {
            switch (err) {
                error.Eof => return null,
                else => |e| return e,
            }
        };
        return val;
    }
};

pub const ParseRespErr = error{Malformed};

const ParsedResp = union(enum) {
    remoteErr: msgpack.Value,
    remoteOk: msgpack.Value,
};

pub fn parseResp(val: msgpack.Value) !ParsedResp {
    switch (val) {
        .Arr => |a| {
            var it: msgpack.ValueIterator = a;
            if (it.count() != 4) {
                std.debug.print("unexpected response format\n", .{});
                return ParseRespErr.Malformed;
            }
            const msgType = (try it.next()).?;
            if (msgType.get_int() != 1) {
                std.debug.print("unexpected message type {f}\n", .{msgType});
                return ParseRespErr.Malformed;
            }
            const msgId = (try it.next()).?;
            if (msgId.get_int() != 1) {
                std.debug.print("unexpected message id {f}\n", .{msgId});
                return ParseRespErr.Malformed;
            }
            const errArr = (try it.next()).?;
            if (!errArr.is_nil()) {
                return ParsedResp{ .remoteErr = errArr };
            }
            const okArr = (try it.next()).?;
            return ParsedResp{ .remoteOk = okArr };
        },
        else => {
            std.debug.print("unexpected response format\n", .{});
            return ParseRespErr.Malformed;
        },
    }
}

const hostPort = struct {
    host: []const u8,
    port: u16,
};

fn checkNumeric(buf: []const u8) bool {
    if (buf.len == 0) {
        return false;
    }
    for (buf) |c| {
        if (c < '0' or c > '9') {
            return false;
        }
    }
    return true;
}

pub fn splitHostPort(buf: []const u8) !hostPort {
    if (buf.len < 1) {
        return error.invaidAddress;
    }
    const idx = mem.lastIndexOfScalar(u8, buf, ':') orelse return error.InvalidAddress;
    if (buf[0] == '[') {
        const end = mem.lastIndexOfScalar(u8, buf, ']') orelse return error.InvalidAddress;
        if (end + 1 != idx) {
            return error.InvalidAddress;
        }
        if (!checkNumeric(buf[(idx + 1)..])) {
            return error.InvalidAddress;
        }
        return hostPort{ .host = buf[1..end], .port = try std.fmt.parseInt(u16, buf[(idx + 1)..], 10) };
    } else {
        if (mem.indexOfScalar(u8, buf[0..idx], ':') != null) {
            return error.InvalidAddress;
        }
        if (!checkNumeric(buf[(idx + 1)..])) {
            return error.InvalidAddress;
        }
        return hostPort{ .host = buf[0..idx], .port = try std.fmt.parseInt(u16, buf[(idx + 1)..], 10) };
    }
}

test "parse addr" {
    const expect = std.testing.expect;
    var hp = try splitHostPort("127.0.0.1:1234");
    try expect(mem.eql(u8, hp.host, "127.0.0.1"));
    try expect(hp.port == 1234);

    hp = try splitHostPort("[::1]:8080");
    try expect(mem.eql(u8, hp.host, "::1"));
    try expect(hp.port == 8080);
}

test "unix" {
    var sock = try net.connectUnixSocket("\\\\.\\pipe\\nvim");
    sock.close();
}

const ReadError = fs.File.ReadError || net.Stream.ReadError;
const WriteError = fs.File.WriteError || net.Stream.WriteError;

const Transport = union(enum) {
    net_stream: net.Stream,
    win_pipe: fs.File,

    fn read(self: *Transport, buf: []u8) ReadError!usize {
        switch (self.*) {
            .net_stream => |s| {
                return s.read(buf);
            },
            .win_pipe => |s| {
                return s.read(buf);
            },
        }
    }
    fn write(self: *Transport, buf: []const u8) WriteError!usize {
        switch (self.*) {
            .net_stream => |s| {
                return s.write(buf);
            },
            .win_pipe => |s| {
                return s.write(buf);
            },
        }
    }
    fn writeAll(self: *Transport, buf: []const u8) WriteError!void {
        switch (self.*) {
            .net_stream => |s| {
                return s.writeAll(buf);
            },
            .win_pipe => |s| {
                return s.writeAll(buf);
            },
        }
    }
    fn close(self: *Transport) void {
        switch (self.*) {
            .net_stream => |s| {
                s.close();
            },
            .win_pipe => |s| {
                s.close();
            },
        }
    }
};
