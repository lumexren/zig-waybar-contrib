const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;
const heap = std.heap;
const mem = std.mem;
const Allocator = mem.Allocator;

pub fn main() !void {
    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: Io.Threaded = .init(allocator, .{});
    const io = threaded.io();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    while (true) {
        try stdout.print("Enter number 1: ", .{});
        try stdout.flush();

        const inputOne = try stdin.takeDelimiterExclusive('\n');
        const allocOne = try allocator.dupe(u8, inputOne);

        stdin.toss(1);

        try stdout.print("Enter number 2: ", .{});
        try stdout.flush();

        const inputTwo = try stdin.takeDelimiterExclusive('\n');
        const allocTwo = try allocator.dupe(u8, inputTwo);

        stdin.toss(1);

        const n1 = try fmt.parseInt(u8, allocOne, 10);
        const n2 = try fmt.parseInt(u8, allocTwo, 10);

        try stdout.print("Sum: {d}\n", .{n1 + n2});
        try stdout.flush();

        break;
    }
}
