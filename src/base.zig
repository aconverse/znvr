const std = @import("std");

pub fn ArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}
