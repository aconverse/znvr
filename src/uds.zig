const std = @import("std");
const mem = std.mem;
const net = std.net;
const FileOpenError = std.fs.File.OpenError;

// Find the best (oldest) neovim socket. Caller takes ownership of returned memory.
pub fn findSocket(alloc: mem.Allocator) ![]u8 {
    // From nvim source:
    // Named pipe format:
    // - Windows: "\\.\pipe\<name>.<pid>.<counter>"
    // - Other: "/tmp/nvim.user/xxx/<name>.<pid>.<counter>"

    // The Nvim tempdir is created in the first available system tempdir:
    //     Unix:    $TMPDIR, /tmp, current-dir, $HOME.
    //     Windows: $TMPDIR, $TMP, $TEMP, $USERPROFILE, current-dir.

    const user = std.posix.getenv("USER") orelse "";
    if (user.len == 0 or mem.indexOfScalar(u8, user, '/') != null) {
        return FileOpenError.BadPathName;
    }

    const tmpdir: []const u8 = blk: {
        const env_tmpdir = std.posix.getenv("TMPDIR") orelse "";
        break :blk if (env_tmpdir.len > 0) env_tmpdir else "/tmp";
    };

    var candidateSocketOut = std.ArrayList(u8).init(alloc);
    defer candidateSocketOut.deinit();

    try candidateSocketOut.appendSlice(tmpdir);
    try candidateSocketOut.appendSlice("/nvim.");
    try candidateSocketOut.appendSlice(user);
    try candidateSocketOut.appendSlice("/");
    const preLen = candidateSocketOut.items.len;

    var bestSocketOut = std.ArrayList(u8).init(alloc);
    defer bestSocketOut.deinit();

    var dir = std.fs.cwd().openDir(candidateSocketOut.items, .{ .iterate = true }) catch |err| {
        std.debug.print("error opening outer sockets dir {s}: {s}\n", .{candidateSocketOut.items, @errorName(err)});
        return err;
    };
    defer dir.close();
    var oldestCtime: i128 = std.math.maxInt(i128);

    var it = dir.iterate();
    while (it.next() catch |err| {
        std.debug.print("error iterating outer sockets dir {s}: {s}\n", .{ candidateSocketOut.items, @errorName(err) });
        // These errors all seem to impy the directory itself cannot be iterated
        return err;
    }) |file| {
        if (file.kind != .directory) {
            continue;
        }
        var dir2 = dir.openDir(file.name, .{ .iterate = true }) catch |err| {
            std.debug.print("WARNING: error opening inner sockets dir {s}: {s}\n", .{ file.name, @errorName(err) });
            continue;
        };
        defer dir2.close();
        var it2 = dir2.iterate();
        while (it2.next() catch {
            // std.debug.print("error iterating inner sockets dir {s}: {s}\n", .{ file.name, @errorName(err) });
            // This inner directory is not iterable, keep working the outer directory
            // continue here continues the outer loop
            continue;
        }) |file2| {
            if (!mem.startsWith(u8, file2.name, "nvim.")) {
                continue;
            }
            if (file2.kind != .unix_domain_socket) {
                continue;
            }
            const stat = dir2.statFile(file2.name) catch {
                continue;
            };
            const ctime = stat.ctime;
            //std.debug.print("{} {} {}\n", .{file2.name, ctime, oldestCtime});
            if (ctime > 0 and ctime < oldestCtime) {
                candidateSocketOut.shrinkRetainingCapacity(preLen);
                try candidateSocketOut.appendSlice(file.name);
                try candidateSocketOut.appendSlice("/");
                try candidateSocketOut.appendSlice(file2.name);
                // TEST socket
                var openedSock = net.connectUnixSocket(candidateSocketOut.items) catch |err| {
                    std.debug.print("WARNING: error opening orphaned(?) socket {s}: {s}\n", .{ candidateSocketOut.items, @errorName(err) });
                    continue;
                };
                openedSock.close();
                bestSocketOut.clearRetainingCapacity();
                try bestSocketOut.appendSlice(candidateSocketOut.items);
                oldestCtime = ctime;
            }
        }
    }
    if (bestSocketOut.items.len != 0) {
        return bestSocketOut.toOwnedSlice();
    }
    return FileOpenError.FileNotFound;
}
