const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const FileOpenError = std.fs.File.OpenError;
const zig_version = builtin.zig_version;

const base = @import("base.zig");
const pipes = @import("pipes.zig");
const uds = @import("uds.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");

const ArrayList = base.ArrayList;

const ArgsError = error{
    ExpectedAfterServername,
};

fn ArgOpt(comptime T: type) type {
    return struct {
        value: ?T,
        names: []const []const u8,
        help: []const u8,
        final: bool,
    };
}

const Opt = union(enum) {
    implicitBool: *ArgOpt(bool),
    nextString: *ArgOpt([]const u8),

    fn nameMatches(self: Opt, name: []const u8) bool {
        switch (self) {
            inline else => |opt| for (opt.names) |n| {
                if (mem.eql(u8, name, n)) {
                    return true;
                }
            },
        }
        return false;
    }
};

var optHelp = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{ "--help", "-h" },
    .help = "show help then exit",
    .final = true,
};
var optPrintServer = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{"--print-server"},
    .help = "print the server selected then exit",
    .final = true,
};
var optServerName = ArgOpt([]const u8){
    .value = null,
    .names = &[_][]const u8{ "--server", "--server-name" },
    .help = "nvim server socket address",
    .final = false,
};
var optRelative = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{"--relative"},
    .help = "treat filenames as relative to nvim's cwd",
    .final = false,
};
var optModeBuffer = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{ "--remote", "--" },
    .help = "open files in buffers",
    .final = true,
};
var optModeTab = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{ "--remote-tab", "--tab" },
    .help = "open files in tabs",
    .final = true,
};
var optModeExpr = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{ "--remote-expr", "--expr" },
    .help = "evaluate expression",
    .final = true,
};
var optModeSend = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{ "--remote-send", "--send" },
    .help = "send keys",
    .final = true,
};
var optModeChangeDir = ArgOpt(bool){
    .value = null,
    .names = &[_][]const u8{ "--remote-cd", "--cd" },
    .help = "change directory",
    .final = true,
};

const KnownOpts = [_]Opt{
    Opt{ .implicitBool = &optHelp },
    Opt{ .implicitBool = &optPrintServer },
    Opt{ .nextString = &optServerName },
    Opt{ .implicitBool = &optModeBuffer },
    Opt{ .implicitBool = &optModeTab },
    Opt{ .implicitBool = &optModeExpr },
    Opt{ .implicitBool = &optModeSend },
    Opt{ .implicitBool = &optModeChangeDir },
};

const Mode = enum {
    NONE,
    BUFFER,
    TAB,
    EXPR,
    SEND,
    CHANGE_DIR,
};

var activeMode = Mode.NONE;

fn setModeFromOpts() void {
    if (optModeBuffer.value == true) {
        activeMode = Mode.BUFFER;
    } else if (optModeTab.value == true) {
        activeMode = Mode.TAB;
    } else if (optModeExpr.value == true) {
        activeMode = Mode.EXPR;
    } else if (optModeSend.value == true) {
        activeMode = Mode.SEND;
    } else if (optModeChangeDir.value == true) {
        activeMode = Mode.CHANGE_DIR;
    }
}

fn usage() !void {
    std.debug.print("znvr sends commands to a remote neovim instance\n\n", .{});
    std.debug.print("Usage znvr [options] [mode option] [files...]\n\n", .{});

    std.debug.print("Options:\n", .{});
    for (KnownOpts) |kopt| {
        switch (kopt) {
            inline else => |opt| {
                std.debug.print("   {s}", .{opt.names[0]});
                for (opt.names[1..]) |name| {
                    std.debug.print(", {s}", .{name});
                }
                std.debug.print("\n", .{});
                std.debug.print("        {s}\n", .{opt.help});
            },
        }
    }
    const serverSelectionInfo: []const u8 = "Server selection:\n" ++
        "znvr always gives the highest priority to the server specified with the\n" ++
        "--server option. If no server is specified on the command line then a\n" ++
        "server specified in the environment variable NVIM is preferred (to enable\n" ++
        "znvr from inside neovim. If that environment variable is not set, then the\n" ++
        "NVIM_LISTEN_ADDRESS environment variable is preferred.\n\n" ++
        "If a server is not specified with any explicit mechanism, then znvr will\n" ++
        "will attempt to find the listen socket of the oldest running nvim on the\n" ++
        "system in an operation system specific manner\n";

    std.debug.print("\n{s}\n", .{serverSelectionInfo});
}

fn parseArgs(args: []const [:0]u8) ![]const [:0]u8 {
    defer setModeFromOpts();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        for (KnownOpts) |opt| {
            if (opt.nameMatches(arg)) {
                switch (opt) {
                    .implicitBool => |boolOpt| {
                        boolOpt.value = true;
                        if (boolOpt.final) {
                            return args[(i + 1)..];
                        }
                    },
                    .nextString => |stringOpt| {
                        if (i + 1 < args.len) {
                            i += 1;
                            stringOpt.value = args[i];
                        } else {
                            return ArgsError.ExpectedAfterServername;
                        }
                        if (stringOpt.final) {
                            return args[(i + 1)..];
                        }
                    },
                }
            }
        }
    }
    return args[i..];
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("leaked\n", .{});
        }
    }

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len <= 1) {
        try usage();
        return 0;
    }

    const files = try parseArgs(args);

    if (optHelp.value == true) {
        try usage();
        return 0;
    }

    if (optPrintServer.value != true and activeMode == Mode.NONE) {
        std.debug.print("No mode specified. See --help for usage\n", .{});
        return 1;
    }

    const servername = try getServerName(alloc) orelse {
        // all expected errors log internally
        //std.debug.print("no server found\n", .{});
        return 1;
    };
    defer alloc.free(servername);
    if (optPrintServer.value == true) {
        std.debug.print("selecting server {s}\n", .{servername});
        return 0;
    }

    switch (activeMode) {
        Mode.BUFFER => if (files.len == 0) {
            std.debug.print("--remote requires files\n", .{});
            return 1;
        },
        Mode.TAB => if (files.len == 0) {
            std.debug.print("--remote-tab requires files\n", .{});
            return 1;
        },
        Mode.EXPR => if (files.len != 1) {
            std.debug.print("--remote-expr requires exactly one argument\n", .{});
            return 1;
        },
        Mode.SEND => if (files.len != 1) {
            std.debug.print("--remote-send requires exactly one argument\n", .{});
            return 1;
        },
        Mode.CHANGE_DIR => if (files.len != 1) {
            std.debug.print("--remote-cd requires exactly one argument\n", .{});
            return 1;
        },
        Mode.NONE => unreachable,
    }

    var conn = rpc.RpcConn.openConn(servername) catch |e| {
        std.debug.print("failed to connect to server: {}\n", .{e});
        return 1;
    };
    defer conn.close();

    if (activeMode == Mode.EXPR) {
        conn.sendExpr(alloc, files[0]) catch |e| {
            std.debug.print("failed to send command to server: {}\n", .{e});
        };
    } else if (activeMode == Mode.SEND) {
        conn.sendKeys(alloc, files[0]) catch |e| {
            std.debug.print("failed to send command to server: {}\n", .{e});
        };
    } else if (activeMode == Mode.CHANGE_DIR) {
        var resolved_dir: ?[]const u8 = null;
        if (optRelative.value != true) {
            const cwd = try std.process.getCwdAlloc(alloc);
            defer alloc.free(cwd);
            resolved_dir = try std.fs.path.resolve(alloc, &[_][]const u8{
                cwd,
                files[0],
            });
        }
        defer if (resolved_dir) |a| alloc.free(a);
        conn.sendChangeDir(alloc, resolved_dir orelse files[0]) catch |e| {
            std.debug.print("failed to send command to server: {}\n", .{e});
        };
    } else {
        const dir: ?[]const u8 = if (optRelative.value != true)
            try std.process.getCwdAlloc(alloc)
        else
            null;
        defer if (dir) |a| alloc.free(a);
        conn.sendLuaOpen(alloc, activeMode == Mode.TAB, dir orelse "", files) catch |e| {
            std.debug.print("failed to send command to server: {}\n", .{e});
        };
    }
    var respBuf = ArrayList(u8).init(alloc);
    defer respBuf.deinit();
    const resp = try pollResp(&conn, &respBuf);
    const parsed = rpc.parseResp(resp) catch |e| {
        if (e == rpc.ParseRespErr.Malformed) {
            return 1;
        }
        return e;
    };

    switch (parsed) {
        .remoteErr => |e| {
            std.debug.print("neovim server returned error:\n{f}\n", .{e});
        },
        .remoteOk => |ok| {
            switch (ok) {
                .Nil => {},
                else => {
                    if (activeMode == Mode.EXPR) {
                        if (zig_version.major == 0 and zig_version.minor <= 14) {
                            std.io.getStdOut().writer().print("{}\n", .{ok}) catch {};
                        } else {
                            var stdout = std.fs.File.stdout();
                            stdout.deprecatedWriter().print("{f}\n", .{ok}) catch {};
                        }
                    } else if (activeMode == Mode.SEND) {
                        // seems to return the number of keys
                    } else if (activeMode == Mode.CHANGE_DIR) {
                        std.debug.print("{f}\n", .{ok});
                    }
                },
            }
        },
    }
    return 0;
}

fn pollResp(conn: *rpc.RpcConn, respBuf: *ArrayList(u8)) !msgpack.Value {
    var resp: ?msgpack.Value = null;
    while (resp == null) {
        resp = try conn.accumResp(respBuf);
    }
    return resp.?;
}

fn remoteFileCmd(alloc: mem.Allocator, files: []const [:0]u8, tabs: bool) ![]const u8 {
    var scratch = ArrayList(u8).init(alloc);
    errdefer scratch.deinit();

    if (tabs) {
        try scratch.appendSlice("tab ");
    }
    try scratch.appendSlice("drop");
    for (files) |f| {
        try scratch.append(' ');
        try scratch.appendSlice(f);
    }
    return scratch.toOwnedSlice();
}

fn searchSocket(alloc: mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return try pipes.findSocket(alloc);
    } else {
        return try uds.findSocket(alloc);
    }
}

fn getServerName(alloc: mem.Allocator) !?[]u8 {
    if (optServerName.value) |name| {
        if (name.len > 0) {
            return try alloc.dupe(u8, name);
        }
    }

    var envmap = try std.process.getEnvMap(alloc);
    defer envmap.deinit();
    if (envmap.get("NVIM")) |s| {
        return try alloc.dupe(u8, s);
    }

    if (envmap.get("NVIM_LISTEN_ADDRESS")) |s| {
        return try alloc.dupe(u8, s);
    }

    return searchSocket(alloc) catch |err| {
        switch (err) {
            FileOpenError.FileNotFound => {
                std.debug.print("No neovim socket found\n", .{});
                return null;
            },
            else => {
                std.debug.print("Failed to discover neovim socket: {}\n", .{err});
                return null;
            },
        }
    };
}
