const std = @import("std");
const base = @import("base.zig");
const znvr = @import("znvr.zig");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("leaked\n", .{});
        }
    }
    const io = base.IoShim{};

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var envmap = try std.process.getEnvMap(alloc);
    defer envmap.deinit();

    return znvr.run(alloc, io, args, &envmap);
}
