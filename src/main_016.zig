const std = @import("std");
const base = @import("base.zig");
const znvr = @import("znvr.zig");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    //defer {
    //    const deinit_status = alloc.deinit();
    //    if (deinit_status == .leak) {
    //        std.debug.print("leaked\n", .{});
    //    }
    //}
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    //defer args.deinit();

    const env = init.environ_map;

    return znvr.run(alloc, io, args, env);
}
