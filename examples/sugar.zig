// TODO this is just a proof of concept, api might change a lot

const std = @import("std");
const dida = @import("dida");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    var sugar = dida.sugar.Sugar.init(allocator);

    const edges = sugar.input();
    const loop = sugar.loop();
    const edges_1 = loop.importNode(edges);
    const reach = loop.loopNode();
    reach.fixpoint(reach
        .index()
        .join(edges_1.project(.{ 1, 0 }).index(), 1)
        .project(.{ 2, 1 })
        .union_(edges_1)
        .index().distinct());
    const out = loop.exportNode(reach).output();

    sugar.build();

    try edges.push(.{ .{ "a", "b" }, .{0}, 1 });
    try edges.push(.{ .{ "b", "c" }, .{0}, 1 });
    try edges.push(.{ .{ "b", "d" }, .{0}, 1 });
    try edges.push(.{ .{ "c", "a" }, .{0}, 1 });
    try edges.push(.{ .{ "b", "c" }, .{1}, -1 });
    try edges.flush();

    try edges.advance(.{1});
    try sugar.doAllWork();
    while (out.pop()) |change_batch| {
        dida.util.dump(change_batch);
    }

    std.debug.print("Advancing!\n", .{});

    try edges.advance(.{2});
    try sugar.doAllWork();
    while (out.pop()) |change_batch| {
        dida.util.dump(change_batch);
    }

    //dida.common.dump(sugar);
}
