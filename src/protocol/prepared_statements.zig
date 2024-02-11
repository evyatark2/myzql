const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;
const PreparedStatement = @import("./../result.zig").PreparedStatement;
const ColumnDefinition41 = @import("./column_definition.zig").ColumnDefinition41;
const DateTime = @import("../temporal.zig").DateTime;
const Duration = @import("../temporal.zig").Duration;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const PrepareRequest = struct {
    query: []const u8,

    pub fn write(q: *const PrepareRequest, writer: *stream_buffered.SmallPacketWriter) !void {
        try packet_writer.writeUInt8(writer, constants.COM_STMT_PREPARE);
        try writer.write(q.query);
    }
};

pub const PrepareOk = struct {
    status: u8,
    statement_id: u32,
    num_columns: u16,
    num_params: u16,

    warning_count: ?u16,
    metadata_follows: ?u8,

    pub fn initFromPacket(packet: *const Packet, capabilities: u32) PrepareOk {
        var prepare_ok_packet: PrepareOk = undefined;

        var reader = PacketReader.initFromPacket(packet);
        prepare_ok_packet.status = reader.readByte();
        prepare_ok_packet.statement_id = reader.readUInt32();
        prepare_ok_packet.num_columns = reader.readUInt16();
        prepare_ok_packet.num_params = reader.readUInt16();

        // Reserved 1 byte
        const b = reader.readByte();
        std.debug.assert(b == 0);

        if (reader.finished()) {
            prepare_ok_packet.warning_count = null;
            prepare_ok_packet.metadata_follows = null;
            return prepare_ok_packet;
        }

        prepare_ok_packet.warning_count = reader.readUInt16();
        if (capabilities & constants.CLIENT_OPTIONAL_RESULTSET_METADATA > 0) {
            prepare_ok_packet.metadata_follows = reader.readByte();
        } else {
            prepare_ok_packet.metadata_follows = null;
        }
        return prepare_ok_packet;
    }
};

pub const BinaryParam = struct {
    type_and_flag: [2]u8, // LSB: type, MSB: flag
    name: []const u8,
    raw: ?[]const u8,
};

pub const ExecuteRequest = struct {
    prep_stmt: *const PreparedStatement,

    capabilities: u32,
    flags: u8 = 0, // Cursor type
    iteration_count: u32 = 1, // Always 1
    new_params_bind_flag: u8 = 1,

    // attributes: []const BinaryParam = &.{}, // Not supported yet

    pub fn writeWithParams(e: *const ExecuteRequest, writer: anytype, params: anytype) !void {
        try packet_writer.writeUInt8(writer, constants.COM_STMT_EXECUTE);
        try packet_writer.writeUInt32(writer, e.prep_stmt.prep_ok.statement_id);
        try packet_writer.writeUInt8(writer, e.flags);
        try packet_writer.writeUInt32(writer, e.iteration_count);

        // const has_attributes_to_write = (e.capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) and e.attributes.len > 0;

        const param_count = e.prep_stmt.prep_ok.num_params;
        if (param_count > 0
        //or has_attributes_to_write
        ) {
            // if (has_attributes_to_write) {
            //     try packet_writer.writeLengthEncodedInteger(writer, e.attributes.len + param_count);
            // }

            // Write Null Bitmap
            // if (has_attributes_to_write) {
            //     try writeNullBitmap(params, e.attributes, writer);
            // } else {
            //     try writeNullBitmapWithAttrs(params, &.{}, writer);
            // }

            try writeNullBitmap(params, writer);

            const col_defs = e.prep_stmt.params;
            if (params.len != col_defs.len) {
                std.log.err("expected column count: {d}, but got {d}", .{ col_defs.len, params.len });
                return error.ParamsCountNotMatch;
            }

            // If a statement is re-executed without changing the params types,
            // the types do not need to be sent to the server again.
            // send type to server (0 / 1)
            try packet_writer.writeLengthEncodedInteger(writer, e.new_params_bind_flag);
            //if (e.new_params_bind_flag > 0) {
            comptime var enum_field_types: [params.len]constants.EnumFieldType = undefined;
            inline for (params, &enum_field_types) |param, *enum_field_type| {
                enum_field_type.* = comptime enumFieldTypeFromParam(param);
            }

            inline for (col_defs, enum_field_types) |col_def, enum_field_type| {
                try packet_writer.writeUInt8(writer, @intFromEnum(enum_field_type));
                if (col_def.flags & constants.UNSIGNED_FLAG > 0) {
                    try packet_writer.writeUInt8(writer, 0x80);
                } else {
                    try packet_writer.writeUInt8(writer, 0);
                }

                // Not supported yet
                // if (e.capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) {
                //     try packet_writer.writeLengthEncodedString(writer, "");
                // }
            }

            // if (has_attributes_to_write) {
            //     for (e.attributes) |b| {
            //         try writer.write(&b.type_and_flag);
            //         try packet_writer.writeLengthEncodedString(writer, b.name);
            //     }
            // }
            // }

            // TODO: Write params and attr as binary values
            // Write params as binary values
            inline for (params, enum_field_types) |param, enum_field_type| {
                // if (enum_field_type == constants.EnumFieldType.MYSQL_TYPE_NULL) {
                //     continue;
                // }
                try writeParamAsFieldType(writer, enum_field_type, param);
            }

            // if (has_attributes_to_write) {
            //     for (e.attributes) |b| {
            //         try writeAttr(b, writer);
            //     }
            // }
        }
    }
};

fn enumFieldTypeFromParam(param: anytype) constants.EnumFieldType {
    const Param = @TypeOf(param);
    const param_type_info = @typeInfo(Param);
    return switch (Param) {
        DateTime => constants.EnumFieldType.MYSQL_TYPE_DATETIME,
        Duration => constants.EnumFieldType.MYSQL_TYPE_TIME,
        else => switch (param_type_info) {
            .Null => return constants.EnumFieldType.MYSQL_TYPE_NULL,
            .Optional => {
                if (param) |p| {
                    return enumFieldTypeFromParam(p);
                } else {
                    return constants.EnumFieldType.MYSQL_TYPE_NULL;
                }
            },
            .Int => |int| {
                if (int.bits <= 8) {
                    return constants.EnumFieldType.MYSQL_TYPE_TINY;
                } else if (int.bits <= 16) {
                    return constants.EnumFieldType.MYSQL_TYPE_SHORT;
                } else if (int.bits <= 32) {
                    return constants.EnumFieldType.MYSQL_TYPE_LONG;
                } else if (int.bits <= 64) {
                    return constants.EnumFieldType.MYSQL_TYPE_LONGLONG;
                }
            },
            .ComptimeInt => {
                if (std.math.minInt(i8) <= param and param <= std.math.maxInt(u8)) {
                    return constants.EnumFieldType.MYSQL_TYPE_TINY;
                } else if (std.math.minInt(i16) <= param and param <= std.math.maxInt(u16)) {
                    return constants.EnumFieldType.MYSQL_TYPE_SHORT;
                } else if (std.math.minInt(i32) <= param and param <= std.math.maxInt(u32)) {
                    return constants.EnumFieldType.MYSQL_TYPE_LONG;
                } else if (std.math.minInt(i64) <= param and param <= std.math.maxInt(u64)) {
                    return constants.EnumFieldType.MYSQL_TYPE_LONGLONG;
                } else {
                    @compileLog("hello");
                }
            },
            .Float => |float| {
                if (float.bits <= 32) {
                    return constants.EnumFieldType.MYSQL_TYPE_FLOAT;
                } else if (float.bits <= 64) {
                    return constants.EnumFieldType.MYSQL_TYPE_DOUBLE;
                }
            },
            .ComptimeFloat => return constants.EnumFieldType.MYSQL_TYPE_DOUBLE, // Safer to assume double
            .Array => |array| {
                switch (@typeInfo(array.child)) {
                    .Int => |int| {
                        if (int.bits == 8) {
                            return constants.EnumFieldType.MYSQL_TYPE_STRING;
                        }
                    },
                    else => {},
                }
            },
            .Enum => return constants.EnumFieldType.MYSQL_TYPE_STRING,
            .Pointer => |pointer| {
                switch (pointer.size) {
                    .One => return enumFieldTypeFromParam(param.*),
                    else => {},
                }
                switch (@typeInfo(pointer.child)) {
                    .Int => |int| {
                        if (int.bits == 8) {
                            switch (pointer.size) {
                                .Slice, .C, .Many => return constants.EnumFieldType.MYSQL_TYPE_STRING,
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
            else => {
                @compileLog(param);
                @compileError("unsupported type");
            },
        },
    };
}

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html#sect_protocol_binary_resultset_row_value
// https://mariadb.com/kb/en/com_stmt_execute/#binary-parameter-encoding
fn writeParamAsFieldType(
    writer: anytype,
    comptime enum_field_type: constants.EnumFieldType,
    param: anytype,
) !void {
    return switch (@typeInfo(@TypeOf(param))) {
        .Optional => if (param) |p| {
            return try writeParamAsFieldType(writer, enum_field_type, p);
        } else {
            return;
        },
        else => switch (enum_field_type) {
            .MYSQL_TYPE_NULL => {},
            .MYSQL_TYPE_TINY => try packet_writer.writeUInt8(writer, uintCast(u8, i8, param)),
            .MYSQL_TYPE_SHORT => try packet_writer.writeUInt16(writer, uintCast(u16, i16, param)),
            .MYSQL_TYPE_LONG => try packet_writer.writeUInt32(writer, uintCast(u32, i32, param)),
            .MYSQL_TYPE_LONGLONG => try packet_writer.writeUInt64(writer, uintCast(u64, i64, param)),
            .MYSQL_TYPE_FLOAT => try packet_writer.writeUInt32(writer, @bitCast(@as(f32, param))),
            .MYSQL_TYPE_DOUBLE => try packet_writer.writeUInt64(writer, @bitCast(@as(f64, param))),
            .MYSQL_TYPE_DATETIME => try writeDateTime(param, writer),
            .MYSQL_TYPE_TIME => try writeDuration(param, writer),
            .MYSQL_TYPE_STRING => try packet_writer.writeLengthEncodedString(writer, stringCast(param)),
            else => {
                @compileLog(enum_field_type);
                @compileLog(param);
                @compileError("unsupported type");
            },
        },
    };
}

fn stringCast(param: anytype) []const u8 {
    switch (@typeInfo(@TypeOf(param))) {
        .Pointer => |pointer| {
            switch (pointer.size) {
                .C, .Many => return std.mem.span(param),
                else => {},
            }
        },
        .Enum => return @tagName(param),
        else => {},
    }

    return param;
}

fn uintCast(comptime UInt: type, comptime Int: type, value: anytype) UInt {
    return switch (@TypeOf(value)) {
        comptime_int => comptimeIntToUInt(UInt, Int, value),
        else => @bitCast(value),
    };
}

fn comptimeIntToUInt(
    comptime UInt: type,
    comptime Int: type,
    comptime int: comptime_int,
) UInt {
    if (comptime (int < 0)) {
        return @bitCast(@as(Int, int));
    } else {
        return int;
    }
}

// To save space the packet can be compressed:
// if year, month, day, hour, minutes, seconds and microseconds are all 0, length is 0 and no other field is sent.
// if hour, seconds and microseconds are all 0, length is 4 and no other field is sent.
// if microseconds is 0, length is 7 and micro_seconds is not sent.
// otherwise the length is 11
fn writeDateTime(dt: DateTime, writer: anytype) !void {
    if (dt.microsecond > 0) {
        try packet_writer.writeUInt8(writer, 11);
        try packet_writer.writeUInt16(writer, dt.year);
        try packet_writer.writeUInt8(writer, dt.month);
        try packet_writer.writeUInt8(writer, dt.day);
        try packet_writer.writeUInt8(writer, dt.hour);
        try packet_writer.writeUInt8(writer, dt.minute);
        try packet_writer.writeUInt8(writer, dt.second);
        try packet_writer.writeUInt32(writer, dt.microsecond);
    } else if (dt.hour > 0 or dt.minute > 0 or dt.second > 0) {
        try packet_writer.writeUInt8(writer, 7);
        try packet_writer.writeUInt16(writer, dt.year);
        try packet_writer.writeUInt8(writer, dt.month);
        try packet_writer.writeUInt8(writer, dt.day);
        try packet_writer.writeUInt8(writer, dt.hour);
        try packet_writer.writeUInt8(writer, dt.minute);
        try packet_writer.writeUInt8(writer, dt.second);
    } else if (dt.year > 0 or dt.month > 0 or dt.day > 0) {
        try packet_writer.writeUInt8(writer, 4);
        try packet_writer.writeUInt16(writer, dt.year);
        try packet_writer.writeUInt8(writer, dt.month);
        try packet_writer.writeUInt8(writer, dt.day);
    } else {
        try packet_writer.writeUInt8(writer, 0);
    }
}

// To save space the packet can be compressed:
// if day, hour, minutes, seconds and microseconds are all 0, length is 0 and no other field is sent.
// if microseconds is 0, length is 8 and micro_seconds is not sent.
// otherwise the length is 12
fn writeDuration(d: Duration, writer: anytype) !void {
    if (d.microseconds > 0) {
        try packet_writer.writeUInt8(writer, 12);
        try packet_writer.writeUInt8(writer, d.is_negative);
        try packet_writer.writeUInt32(writer, d.days);
        try packet_writer.writeUInt8(writer, d.hours);
        try packet_writer.writeUInt8(writer, d.minutes);
        try packet_writer.writeUInt8(writer, d.seconds);
        try packet_writer.writeUInt32(writer, d.microseconds);
    } else if (d.days > 0 or d.hours > 0 or d.minutes > 0 or d.seconds > 0) {
        try packet_writer.writeUInt8(writer, 8);
        try packet_writer.writeUInt8(writer, d.is_negative);
        try packet_writer.writeUInt32(writer, d.days);
        try packet_writer.writeUInt8(writer, d.hours);
        try packet_writer.writeUInt8(writer, d.minutes);
        try packet_writer.writeUInt8(writer, d.seconds);
    } else {
        try packet_writer.writeUInt8(writer, 0);
    }
}

fn writeNullBitmap(params: anytype, writer: anytype) !void {
    comptime var pos: usize = 0;
    var byte: u8 = 0;
    var current_bit: u8 = 1;
    inline for (params) |param| {
        pos += 1;
        if (isNull(param)) {
            byte |= current_bit;
        }
        current_bit <<= 1;

        if (pos == 8) {
            try packet_writer.writeUInt8(writer, byte);
            byte = 0;
            current_bit = 1;
            pos = 0;
        }
    }
    if (pos > 0) {
        try packet_writer.writeUInt8(writer, byte);
    }
}

fn writeNullBitmapWithAttrs(params: anytype, attributes: []const BinaryParam, writer: anytype) !void {
    std.log.warn("\n", .{});
    const byte_count = (params.len + attributes.len + 7) / 8;
    for (0..byte_count) |i| {
        const start = i * 8;
        const end = (i + 1) * 8;

        const byte: u8 = blk: {
            if (params.len >= end) {
                break :blk nullBitsParams(params, start);
            } else if (start >= params.len) {
                break :blk nullBitsAttrs(attributes[(start - params.len)..]);
            } else {
                break :blk nullBitsParamsAttrs(params, start, attributes);
            }
        };

        // [1,1,1,1] [1,1,1]
        // start = 0, end = 8
        std.log.warn("byte: {d}", .{byte});
        try packet_writer.writeUInt8(writer, byte);
    }
}

pub fn nullBitsParams(params: anytype, start: usize) u8 {
    var byte: u8 = 0;

    var current_bit: u8 = 1;

    const end = comptime if (params.len > 8) 8 else params.len;
    inline for (params, 0..) |param, i| {
        if (i >= end) break;
        if (i >= start) {
            if (isNull(param)) {
                byte |= current_bit;
            }
            current_bit <<= 1;
        }
    }

    return byte;
}

pub fn nullBitsAttrs(attrs: []const BinaryParam) u8 {
    const final_attrs = if (attrs.len > 8) attrs[0..8] else attrs;

    var byte: u8 = 0;
    var current_bit: u8 = 1;
    for (final_attrs) |p| {
        if (p.raw == null) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }
    return byte;
}

pub fn nullBitsParamsAttrs(params: anytype, start: usize, attrs: []const BinaryParam) u8 {
    const final_attributes = if (attrs.len > 8) attrs[0..8] else attrs;

    var byte: u8 = 0;
    var current_bit: u8 = 1;

    inline for (params, 0..) |param, i| {
        if (i >= start) {
            if (isNull(param)) byte |= current_bit;
            current_bit <<= 1;
        }
    }

    for (final_attributes) |p| {
        if (p.raw == null) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }

    return byte;
}

inline fn isNull(param: anytype) bool {
    return switch (@typeInfo(@TypeOf(param))) {
        inline .Optional => if (param) |p| isNull(p) else true,
        inline .Null => true,
        inline else => false,
    };
}

fn nonNullBinaryParam() BinaryParam {
    return .{
        .type_and_flag = .{ 0x00, 0x00 },
        .name = "foo",
        .raw = "bar",
    };
}

fn nullBinaryParam() BinaryParam {
    return .{
        .type_and_flag = .{ 0x00, 0x00 },
        .name = "hello",
        .raw = null,
    };
}

test "writeNullBitmap" {
    const some_param = nonNullBinaryParam();
    const null_param = nullBinaryParam();

    const tests = .{
        .{
            .params = &.{1},
            .attributes = &.{some_param},
            .expected = &[_]u8{0b00000000},
        },
        .{
            .params = &.{ null, @as(?u8, null) },
            .attributes = &.{null_param},
            .expected = &[_]u8{0b00000111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null },
            .attributes = &.{},
            .expected = &[_]u8{0b11111111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null, null },
            .attributes = &.{},
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{},
            .attributes = &.{ null_param, null_param, null_param, null_param, null_param, null_param, null_param, null_param, null_param },
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{},
            .attributes = &.{ null_param, null_param, null_param, null_param, null_param, null_param, null_param, null_param },
            .expected = &[_]u8{0b11111111},
        },
        .{
            .params = &.{},
            .attributes = &.{ null_param, null_param, null_param, null_param, null_param, null_param, null_param },
            .expected = &[_]u8{0b01111111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null },
            .attributes = &.{null_param},
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{ null, null, null, null, null, null, null },
            .attributes = &.{ null_param, null_param },
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{ null, null, null, null },
            .attributes = &.{ null_param, null_param, null_param, null_param },
            .expected = &[_]u8{0b11111111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null, null },
            .attributes = &.{ null_param, null_param },
            .expected = &[_]u8{ 0b11111111, 0b00000111 },
        },
    };

    inline for (tests) |t| {
        var buffer: [4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        _ = try writeNullBitmapWithAttrs(t.params, t.attributes, &fbs);

        const written = fbs.buffer[0..fbs.pos];
        try std.testing.expectEqualSlices(u8, t.expected, written);
    }
}
