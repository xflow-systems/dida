const std = @import("std");
const dida = @import("../../core/dida.zig");

const c = @cImport({
    @cInclude("node_api.h");
});

var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .never_unmap = true,
}){};
var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
const allocator = &arena.allocator;

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    napiExportFn(env, exports, napiWrapFn(GraphBuilder_init), "GraphBuilder_init");
    napiExportFn(env, exports, napiWrapFn(dida.GraphBuilder.addSubgraph), "GraphBuilder_addSubgraph");
    napiExportFn(env, exports, napiWrapFn(dida.GraphBuilder.addNode), "GraphBuilder_addNode");
    napiExportFn(env, exports, napiWrapFn(dida.GraphBuilder.finishAndClear), "GraphBuilder_finishAndClear");

    return exports;
}

fn GraphBuilder_init() !dida.GraphBuilder {
    return dida.GraphBuilder.init(allocator);
}

const SerdeStrategy = enum {
    External,
    Value,
};
fn serdeStrategy(comptime T: type) SerdeStrategy {
    return switch (@typeInfo(T)) {
        .Fn => .Value, // TODO
        else => switch (T) {
            *dida.GraphBuilder,
            dida.GraphBuilder,
            *dida.Graph,
            dida.Graph,
            => .External,

            void,
            usize,
            dida.Timestamp,
            dida.Value,
            dida.Row,
            dida.Subgraph,
            dida.Node,
            ?dida.Node,
            [2]dida.Node,
            dida.NodeSpec,
            std.meta.TagType(dida.NodeSpec),
            dida.NodeSpec.MapSpec,
            dida.NodeSpec.JoinSpec,
            dida.NodeSpec.TimestampPushSpec,
            dida.NodeSpec.TimestampPopSpec,
            dida.NodeSpec.TimestampIncrementSpec,
            dida.NodeSpec.IndexSpec,
            dida.NodeSpec.UnionSpec,
            dida.NodeSpec.DistinctSpec,
            dida.NodeSpec.OutputSpec,
            => .Value,

            else => @compileError("No SerdeStrategy for " ++ @typeName(T)),
        },
    };
}

// --- helpers ---

fn napiCall(comptime napi_fn: anytype, args: anytype, comptime ReturnType: type) ReturnType {
    if (ReturnType != void) {
        var result: ReturnType = undefined;
        const status: c.napi_status = @call(.{}, napi_fn, args ++ .{&result});
        dida.common.assert(status == .napi_ok, "Call returned status {}", .{status});
        return result;
    } else {
        const status: c.napi_status = @call(.{}, napi_fn, args);
        dida.common.assert(status == .napi_ok, "Call returned status {}", .{status});
    }
}

fn napiExportFn(env: c.napi_env, exports: c.napi_value, export_fn: c.napi_callback, export_fn_name: [:0]const u8) void {
    const napi_fn = napiCall(c.napi_create_function, .{ env, export_fn_name, export_fn_name.len, export_fn, null }, c.napi_value);
    napiCall(c.napi_set_named_property, .{ env, exports, export_fn_name, napi_fn }, void);
}

fn napiWrapFn(comptime zig_fn: anytype) c.napi_callback {
    return struct {
        fn wrappedMethod(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
            var zig_args: std.meta.ArgsTuple(@TypeOf(zig_fn)) = undefined;
            const napi_args = napiGetCbInfo(env, info, zig_args.len).args;
            comptime var i: usize = 0;
            inline while (i < zig_args.len) : (i += 1) {
                const napi_arg = napi_args[i];
                const zig_arg_type = @TypeOf(zig_args[i]);
                zig_args[i] = switch (comptime serdeStrategy(zig_arg_type)) {
                    .External => napiGetExternal(env, napi_arg, zig_arg_type),
                    .Value => napiGetValue(env, napi_arg, zig_arg_type),
                };
            }
            const result = @call(.{}, zig_fn, zig_args) catch |err| dida.common.panic("{}", .{err});
            switch (comptime serdeStrategy(@TypeOf(result))) {
                .External => {
                    const result_ptr = allocator.create(@TypeOf(result)) catch |err| dida.common.panic("{}", .{err});
                    result_ptr.* = result;
                    return napiCreateExternal(env, result_ptr);
                },
                .Value => {
                    return napiCreateValue(env, result);
                },
            }
        }
    }.wrappedMethod;
}

fn napiGetCbInfo(env: c.napi_env, info: c.napi_callback_info, comptime expected_num_args: usize) struct { args: [expected_num_args]c.napi_value, this: c.napi_value } {
    var actual_num_args: usize = expected_num_args;
    var args: [expected_num_args]c.napi_value = undefined;
    var this: c.napi_value = undefined;
    napiCall(c.napi_get_cb_info, .{ env, info, &actual_num_args, if (expected_num_args == 0) null else @ptrCast([*]c.napi_value, &args), &this, null }, void);
    dida.common.assert(actual_num_args == expected_num_args, "Expected {} args, got {} args", .{ expected_num_args, actual_num_args });
    return .{
        .args = args,
        .this = this,
    };
}

const usize_bits = @bitSizeOf(usize);
comptime {
    if (usize_bits != 64 and usize_bits != 32) {
        @compileError("Can only handle 32 bit or 64 bit architectures");
    }
}

fn napiCreateExternal(env: c.napi_env, value: anytype) c.napi_value {
    if (comptime serdeStrategy(@TypeOf(value)) != .External)
        @compileError("Used napiCreateExternal on a type that is expected to require napiCreateValue: " ++ @typeName(@TypeOf(value)));
    const info = @typeInfo(@TypeOf(value));
    if (!(info == .Pointer and info.Pointer.size == .One))
        @compileError("napiCreateExternal should be called with *T, got " ++ @typeName(@TypeOf(value)));
    return napiCall(c.napi_create_external, .{ env, @ptrCast(*c_void, value), null, null }, c.napi_value);
}

fn napiGetExternal(env: c.napi_env, value: c.napi_value, comptime ReturnType: type) ReturnType {
    if (comptime serdeStrategy(ReturnType) != .External)
        @compileError("Used napiGetExternal on a type that is expected to require napiGetValue: " ++ @typeName(ReturnType));
    const info = @typeInfo(ReturnType);
    if (!(info == .Pointer and info.Pointer.size == .One))
        @compileError("napiGetExternal should be called with *T, got " ++ @typeName(ReturnType));
    const ptr = napiCall(c.napi_get_value_external, .{ env, value }, ?*c_void);
    return @ptrCast(ReturnType, @alignCast(@alignOf(info.Pointer.child), ptr));
}

fn napiCreateValue(env: c.napi_env, value: anytype) c.napi_value {
    if (comptime serdeStrategy(@TypeOf(value)) != .Value)
        @compileError("Used napiCreateValue on a type that is expected to require napiCreateExternal: " ++ @typeName(@TypeOf(value)));
    const info = @typeInfo(@TypeOf(value));
    switch (info) {
        .Int => {
            const cast_value = switch (@TypeOf(value)) {
                usize => @intCast(isize, value),
                else => value,
            };
            const napi_fn = switch (@TypeOf(cast_value)) {
                isize => if (usize_bits == 64) c.napi_create_int64 else c.napi_create_int32,
                else => dida.common.panic("Don't know how to create napi value for {}", @TypeOf(cast_value)),
            };
            return napiCall(napi_fn, .{ env, cast_value }, c.napi_value);
        },
        .Struct => |struct_info| {
            // TODO would like to use napi_new_instance to name this object, but it requires having already registered a constructor
            var result = napiCall(c.napi_create_object, .{env}, c.napi_value);
            inline for (struct_info.fields) |field_info| {
                var field_name: [field_info.name.len:0]u8 = undefined;
                std.mem.copy(u8, &field_name, field_info.name);
                field_name[field_info.name.len] = 0;
                const field_value = napiCreateValue(env, @field(value, field_info.name));
                napiCall(c.napi_set_named_property, .{ env, result, &field_name, field_value }, void);
            }
            return result;
        },
        else => @compileError("Dont know how to create value of type " ++ @typeName(@TypeOf(value))),
    }
}

fn napiGetValue(env: c.napi_env, value: c.napi_value, comptime ReturnType: type) ReturnType {
    if (comptime serdeStrategy(ReturnType) != .Value)
        @compileError("Used napiGetValue on a type that is expected to require napiGetExternal: " ++ @typeName(ReturnType));
    const info = @typeInfo(ReturnType);
    switch (info) {
        .Int => {
            const napi_fn = switch (ReturnType) {
                usize, isize => if (usize_bits == 64) c.napi_get_value_int64 else c.napi.get_value_int32,
                else => dida.common.panic("Don't know how to get napi value for {}", @TypeOf(cast_value)),
            };
            const CastType = switch (ReturnType) {
                usize => isize,
                else => ReturnType,
            };
            const result = napiCall(napi_fn, .{ env, value }, CastType);
            return @intCast(ReturnType, result);
        },
        .Struct => |struct_info| {
            var result: ReturnType = undefined;
            inline for (struct_info.fields) |field_info| {
                var field_name: [field_info.name.len:0]u8 = undefined;
                std.mem.copy(u8, &field_name, field_info.name);
                field_name[field_info.name.len] = 0;
                const field_value = napiCall(c.napi_get_named_property, .{ env, value, &field_name }, c.napi_value);
                @field(result, field_info.name) = napiGetValue(env, field_value, field_info.field_type);
            }
            return result;
        },
        .Union => |union_info| {
            if (union_info.tag_type) |tag_type| {
                const tag = napiGetValue(env, napiCall(c.napi_get_named_property, .{ env, value, "tag" }, c.napi_value), tag_type);
                inline for (@typeInfo(tag_type).Enum.fields) |enum_field_info, i| {
                    if (@enumToInt(tag) == enum_field_info.value) {
                        const union_field_info = union_info.fields[i];
                        const payload = napiGetValue(env, napiCall(c.napi_get_named_property, .{ env, value, "payload" }, c.napi_value), union_field_info.field_type);
                        return @unionInit(ReturnType, union_field_info.name, payload);
                    }
                }
                unreachable;
            } else {
                @compileError("Can't get value for untagged union type " ++ @typeName(ReturnType));
            }
        },
        .Enum => |enum_info| {
            comptime var max_len: usize = 0;
            inline for (enum_info.fields) |field_info| {
                comptime {
                    max_len = dida.common.max(max_len, field_info.name.len);
                }
            }
            // max_len+1 to make space for null byte :(
            var buffer: [max_len + 1]u8 = undefined;
            const buffer_size = napiCall(c.napi_get_value_string_utf8, .{ env, value, &buffer, max_len + 1 }, usize);
            const tag_name = buffer[0..buffer_size];
            inline for (enum_info.fields) |field_info| {
                if (std.mem.eql(u8, tag_name, field_info.name)) {
                    return @intToEnum(ReturnType, field_info.value);
                }
            }
            dida.common.panic("Type {} does not contain a tag named \"{}\"", .{ @typeName(ReturnType), tag_name });
        },
        .Optional => |optional_info| {
            const napi_type = napiCall(c.napi_typeof, .{ env, value }, c.napi_valuetype);
            return switch (napi_type) {
                .napi_undefined, .napi_null => null,
                else => napiGetValue(env, value, optional_info.child),
            };
        },
        .Array => |array_info| {
            dida.common.TODO();
        },
        .Void => {
            return {};
        },
        .Fn => {
            dida.common.TODO();
        },
        else => @compileError("Dont know how to get value for type " ++ @typeName(ReturnType)),
    }
}