const std = @import("std");
const builtin = @import("builtin");

const zig_version = builtin.zig_version;

pub fn ArrayList(comptime T: type) type {
    if (zig_version.major == 0 and zig_version.minor <= 14) {
        return std.ArrayList(T);
    } else {
        return std.array_list.AlignedManaged(T, null);
    }
}
