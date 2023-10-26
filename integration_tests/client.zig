const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;

test "ping" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    try c.ping();
}

test "query database create and drop" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    try c.query("CREATE DATABASE testdb");
    try c.query("DROP DATABASE testdb");
}

// test "query select 1" {
//     var c = Client.init(test_config, std.testing.allocator);
//     defer c.deinit();
//
//     try c.query("show databases");
// }
