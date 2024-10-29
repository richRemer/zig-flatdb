const std = @import("std");
const QuickBuild = @import("qb.zig").QuickBuild;

pub fn build(b: *std.Build) !void {
    try QuickBuild(.{
        .src_path = ".",
        .outs = .{
            .flatdb = .{ .gen = .{ .mod, .unit } },
        },
    }).setup(b);
}
