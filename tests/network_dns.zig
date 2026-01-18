const std = @import("std");
const network = @import("network.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const test_domains = [_][]const u8{
        "google.com",
        "example.com",
        "cloudflare.com",
    };

    std.debug.print("Testing pure Zig DNS resolver...\n\n", .{});

    for (test_domains) |domain| {
        std.debug.print("Resolving {s}... ", .{domain});

        if (try network.resolveIP(allocator, domain, 80)) |ip| {
            defer allocator.free(ip);
            std.debug.print("✓ {s}\n", .{ip});
        } else {
            std.debug.print("✗ Failed\n", .{});
        }
    }

    std.debug.print("\nAll tests completed!\n", .{});
}
