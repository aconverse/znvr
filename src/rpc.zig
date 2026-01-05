const builtin = @import("builtin");
const std = @import("std");
const fs = std.fs;
//const io = std.io;
const mem = std.mem;
const net = std.net;
//const os = std.os;
const posix = std.posix;
const base = @import("base.zig");
const msgpack = @import("msgpack.zig");
const pipes = @import("pipes.zig");
const ArrayList = base.ArrayList;

const openScript = @embedFile("openfiles.lua");

pub const RpcConn = struct {
    msgId: u32,
    tp: Transport,
    reader: TransportReader,
    rbuf: []u8,
    writer: TransportWriter,

    pub fn openConn(alloc: mem.Allocator, addrBuf: []const u8) !RpcConn {
        const rbuf = try alloc.alloc(u8, 4096);
        errdefer alloc.free(rbuf);

        var tp = tp: {
            if (builtin.os.tag == .windows and mem.startsWith(u8, addrBuf, "\\\\.\\pipe\\")) {
                const file = try pipes.connectNamedPipe(addrBuf);
                break :tp Transport{ .win_pipe = file };
            } else if (net.has_unix_sockets and mem.indexOfAny(u8, addrBuf, "/\\") != null) {
                const stream = try net.connectUnixSocket(addrBuf);
                break :tp Transport{ .net_stream = stream };
            } else {
                const hp = try splitHostPort(addrBuf);
                const addr = try net.Address.parseIp(hp.host, hp.port);
                const stream = try net.tcpConnectToAddress(addr);
                break :tp Transport{ .net_stream = stream };
            }
        };

        return RpcConn{
            .msgId = 0,
            .tp = tp,
            .reader = tp.reader(rbuf),
            .rbuf = rbuf,
            .writer = tp.writer(&.{}),
        };
    }
    pub fn close(self: *RpcConn, alloc: mem.Allocator) void {
        self.writer.interface().flush() catch {};
        alloc.free(self.rbuf);
        self.rbuf = undefined;
        self.reader = undefined;
        self.writer = undefined;
        self.tp.close();
    }

    pub fn sendCmd(self: *RpcConn, alloc: mem.Allocator, cmd: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_command");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, cmd);

        const w = self.writer.interface();
        try w.writeAll(buf.items);
        try w.flush();
    }

    pub fn sendExpr(self: *RpcConn, alloc: mem.Allocator, expr: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_eval");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, expr);

        const w = self.writer.interface();
        try w.writeAll(buf.items);
        try w.flush();
    }

    pub fn sendLuaOpen(self: *RpcConn, alloc: mem.Allocator, tabs: bool, dir: []const u8, files: []const [:0]u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        const values = try alloc.alloc(msgpack.Value, files.len);
        for (files, values) |file, *value| {
            value.* = .{ .Str = file };
        }
        defer alloc.free(values);

        var buf = ArrayList(u8).init(alloc);
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
        try msgpack.pack_arr(&buf, values);

        const w = self.writer.interface();
        try w.writeAll(buf.items);
        try w.flush();
    }

    pub fn sendChangeDir(self: *RpcConn, alloc: mem.Allocator, dir: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = ArrayList(u8).init(alloc);
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

        const w = self.writer.interface();
        try w.writeAll(buf.items);
        try w.flush();
    }

    pub fn sendKeys(self: *RpcConn, alloc: mem.Allocator, cmd: []const u8) !void {
        const msgId: u32 = self.msgId + 1;
        self.msgId = msgId;

        var buf = ArrayList(u8).init(alloc);
        defer buf.deinit();
        try msgpack.pack_raw(&buf, 0x94);
        try msgpack.pack_raw(&buf, 0x0);
        try msgpack.pack_int(&buf, msgId);
        try msgpack.pack_str(&buf, "nvim_input");
        try msgpack.pack_raw(&buf, 0x91);
        try msgpack.pack_str(&buf, cmd);

        const w = self.writer.interface();
        try w.writeAll(buf.items);
        try w.flush();
    }
};

pub const ParseRespErr = error{Malformed};

const ParsedResp = union(enum) {
    remoteErr: ArrayList(u8),
    remoteOk: ArrayList(u8),

    pub fn deinit(self: *ParsedResp) void {
        switch (self.*) {
            .remoteErr => |v| {
                v.deinit();
            },
            .remoteOk => |v| {
                v.deinit();
            },
        }
    }
};

pub fn parseResp(conn: *RpcConn, alloc: mem.Allocator) !ParsedResp {
    const buf = try alloc.alloc(u8, 4096);
    defer alloc.free(buf);
    var reader = conn.tp.reader(buf);
    const iface = reader.interface();
    var val = try msgpack.unpack_val(alloc, iface);
    defer val.deinit(alloc);
    switch (val) {
        .Arr => |a| {
            if (a.items.len != 4) {
                std.debug.print("unexpected response format\n", .{});
                return ParseRespErr.Malformed;
            }
            const msgType = a.items[0];
            if (msgType.get_int() != 1) {
                std.debug.print("unexpected message type {f}\n", .{msgType});
                return ParseRespErr.Malformed;
            }
            const msgId = a.items[1];
            if (msgId.get_int() != 1) {
                std.debug.print("unexpected message id {f}\n", .{msgId});
                return ParseRespErr.Malformed;
            }
            const err = a.items[2];
            if (!err.is_nil()) {
                var list = ArrayList(u8).init(alloc);
                errdefer list.deinit();
                try list.print("{f}", .{err});
                return ParsedResp{ .remoteErr = list };
            }
            const ok = a.items[3];
            var list = ArrayList(u8).init(alloc);
            errdefer list.deinit();
            try list.print("{f}", .{ok});
            return ParsedResp{ .remoteOk = list };
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

    fn reader(self: *Transport, buf: []u8) TransportReader {
        switch (self.*) {
            .net_stream => |s| {
                return TransportReader{ .net_stream = s.reader(buf) };
            },
            .win_pipe => |s| {
                return TransportReader{ .win_pipe = s.readerStreaming(buf) };
            },
        }
    }
    fn writer(self: *Transport, buf: []u8) TransportWriter {
        switch (self.*) {
            .net_stream => |s| {
                return TransportWriter{ .net_stream = s.writer(buf) };
            },
            .win_pipe => |s| {
                return TransportWriter{ .win_pipe = s.writerStreaming(buf) };
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

const TransportReader = union(enum) {
    net_stream: net.Stream.Reader,
    win_pipe: fs.File.Reader,

    fn interface(self: *TransportReader) *std.Io.Reader {
        switch (self.*) {
            .net_stream => |*s| {
                return s.interface();
            },
            .win_pipe => |*s| {
                return &s.interface;
            },
        }
    }
};

const TransportWriter = union(enum) {
    net_stream: net.Stream.Writer,
    win_pipe: fs.File.Writer,

    fn interface(self: *TransportWriter) *std.Io.Writer {
        switch (self.*) {
            .net_stream => |*s| {
                return &s.interface;
            },
            .win_pipe => |*s| {
                return &s.interface;
            },
        }
    }
};
