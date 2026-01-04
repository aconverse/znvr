const std = @import("std");
const zig_version = @import("builtin").zig_version;

pub const FileOpenError = if (zig_version.major == 0 and zig_version.minor <= 15) std.fs.File.OpenError else std.Io.File.OpenError;
pub const FileReaderError = if (zig_version.major == 0 and zig_version.minor <= 15) std.fs.File.ReadError else std.Io.File.Reader.Error;
pub const FileWriterError = if (zig_version.major == 0 and zig_version.minor <= 15) std.fs.File.WriteError else std.Io.File.Writer.Error;
pub const NetStreamReaderError = if (zig_version.major == 0 and zig_version.minor <= 15) std.net.Stream.ReadError else std.Io.net.Stream.Reader.Error;
pub const NetStreamWriterError = if (zig_version.major == 0 and zig_version.minor <= 15) std.net.Stream.WriteError else std.Io.net.Stream.Writer.Error;

pub const IoShim = if (zig_version.major == 0 and zig_version.minor <= 15) struct {} else std.Io;

pub fn ioBasic() IoShim {
    return if (zig_version.major == 0 and zig_version.minor <= 15)
        IoShim{}
    else
        std.Io.Threaded.global_single_threaded.ioBasic();
}

pub const FsShim = if (zig_version.major == 0 and zig_version.minor <= 15) struct {
    pub const Dir = struct {
        dir: std.fs.Dir,
        pub fn cwd() Dir {
            return Dir{ .dir = std.fs.cwd() };
        }
        pub fn openDir(self: Dir, _: IoShim, sub_path: []const u8, options: std.fs.Dir.OpenOptions) !Dir {
            return Dir{ .dir = try self.dir.openDir(sub_path, options) };
        }
        pub fn iterate(self: Dir) Iterator {
            return Iterator{ .it = self.dir.iterate() };
        }
        pub fn close(self: *Dir, _: IoShim) void {
            return self.dir.close();
        }
        pub fn openFileAbsolute(_: IoShim, absolute_path: []const u8, flags: File.OpenFlags) !File {
            return std.fs.openFileAbsolute(absolute_path, flags);
        }
        pub const Iterator = struct {
            it: std.fs.Dir.Iterator,
            pub fn next(self: *Iterator, _: IoShim) !?std.fs.Dir.Entry {
                return self.it.next();
            }
        };
    };
    pub const File = std.fs.File;
} else struct {
    pub const Dir = std.Io.Dir;
    pub const File = std.Io.File;
};

pub const NetShim = if (zig_version.major == 0 and zig_version.minor <= 15) struct {
    pub const Stream = std.net.Stream;
    pub const IpAddress = struct {
        addr: std.net.Address,
        pub fn parse(text: []const u8, port: u16) !IpAddress {
            return IpAddress{ .addr = try std.net.Address.parseIp(text, port) };
        }
    };
    pub const has_unix_sockets = std.net.has_unix_sockets;
} else std.Io.net;

pub fn ArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}
