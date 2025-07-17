const std = @import("std");
const mem = std.mem;
const win32 = std.os.windows;

const HANDLE = win32.HANDLE;
const DWORD = win32.DWORD;
const BOOL = win32.BOOL;
const FILETIME = win32.FILETIME;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetProcessTimes(in_hProcess: HANDLE, out_lpCreationTime: *FILETIME, out_lpExitTime: *FILETIME, out_lpKernelTime: *FILETIME, out_lpUserTime: *FILETIME) callconv(.winapi) BOOL;

const FileOpenError = std.fs.File.OpenError;

fn fileTimeToU64(ft: FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

fn getProcCreationTime(pid: u32) u64 {
    const PROCESS_QUERY_INFORMATION: DWORD = 0x400;

    const hProcess = OpenProcess(PROCESS_QUERY_INFORMATION, win32.FALSE, pid);
    defer _ = win32.CloseHandle(hProcess);
    //var ftCreation align(8) = mem.zeroes(FILETIME);
    var ftCreation = mem.zeroes(FILETIME);
    var ft1 = mem.zeroes(FILETIME);
    var ft2 = mem.zeroes(FILETIME);
    var ft3 = mem.zeroes(FILETIME);
    if (0 == GetProcessTimes(hProcess, &ftCreation, &ft1, &ft2, &ft3)) {
        return std.math.maxInt(i64);
    }
    return fileTimeToU64(ftCreation);
}

fn extractPid(pipename: []const u8) ?u32 {
    var it = mem.splitScalar(u8, pipename, '.');
    _ = it.first();
    const spid = it.next() orelse return null;

    if (spid.len == 0) {
        return null;
    }
    const upid = std.fmt.parseUnsigned(u32, spid, 10) catch {
        return null;
    };
    return upid;
}

// Find the best (oldest) neovim socket. Caller takes ownership of returned memory.
pub fn findSocket(alloc: mem.Allocator) ![]u8 {
    // From nvim source:
    // Named pipe format:
    // - Windows: "\\.\pipe\<name>.<pid>.<counter>"
    // - Other: "/tmp/nvim.user/xxx/<name>.<pid>.<counter>"
    var bestPipeOut = std.ArrayList(u8).init(alloc);
    defer bestPipeOut.deinit();

    var dir = try std.fs.cwd().openDir("\\\\.\\pipe\\", .{ .iterate = true });
    defer dir.close();
    var oldest_ctime: u64 = std.math.maxInt(u64);

    var it = dir.iterate();
    while (try it.next()) |file| {
        if (file.kind != .file) {
            continue;
        }
        if (!mem.startsWith(u8, file.name, "nvim.")) {
            continue;
        }

        const pid = extractPid(file.name);

        const ctime = if (pid) |val| getProcCreationTime(val) else 0;
        //std.debug.print("pipe: {s} {s} {?} {?}\n", .{ file.name, @tagName(file.kind), pid, ctime });

        if (ctime != 0 and ctime < oldest_ctime) {
            bestPipeOut.resize(0) catch unreachable;
            try bestPipeOut.appendSlice("\\\\.\\pipe\\");
            try bestPipeOut.appendSlice(file.name);
            oldest_ctime = ctime;
        }
    }
    if (bestPipeOut.items.len != 0) {
        return bestPipeOut.toOwnedSlice();
    }
    return FileOpenError.FileNotFound;
}

pub fn connectNamedPipe(name: []const u8) !std.fs.File {
    const flags = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_write };
    return std.fs.openFileAbsolute(name, flags);
}
