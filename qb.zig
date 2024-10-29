//! Copyright 2024 Richard Remer
//!
//! Permission is hereby granted, free of charge, to any person obtaining a
//! copy of this software and associated documentation files (the “Software”),
//! to deal in the Software without restriction, including without limitation
//! the rights to use, copy, modify, merge, publish, distribute, sublicense,
//! and/or sell copies of the Software, and to permit persons to whom the
//! Software is furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in
//! all copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//! THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//! FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//! DEALINGS IN THE SOFTWARE.

const std = @import("std");
const mem = std.mem;
const Type = std.builtin.Type;

/// Initialize a build based on build spec.
pub fn QuickBuild(comptime spec: anytype) type {
    return struct {
        /// Build context.
        pub const Context = struct {
            build: *std.Build,
            deps: Dependencies(spec),
            target: std.Build.ResolvedTarget,
            optimize: std.builtin.OptimizeMode,
            debug: bool,

            pub fn init(b: *std.Build) Context {
                const debug = b.option(
                    bool,
                    "quick-build-debug",
                    "Enable QuickBuild debug log.",
                ) orelse false;

                const context = Context{
                    .build = b,
                    .deps = .{},
                    .target = b.standardTargetOptions(.{}),
                    .optimize = b.standardOptimizeOption(.{}),
                    .debug = debug,
                };

                context.log("b.standardTargetOptions(.{{}})", .{});
                context.log("b.standardOptimizeOption(.{{}})", .{});

                return context;
            }

            pub fn log(
                this: Context,
                comptime format: []const u8,
                args: anytype,
            ) void {
                if (this.debug) qb_log.debug(format, args);
            }
        };

        /// Setup a build based on the build spec.
        pub fn setup(b: *std.Build) !void {
            var context = Context.init(b);
            const Spec = @TypeOf(spec);

            context.log("test_step = b.step(\"test\", \"Run unit tests\")", .{});
            _ = b.step("test", "Run unit tests");

            inline for (@typeInfo(Dependencies(spec)).@"struct".fields) |f| {
                const name = f.name;

                context.log("{s} = b.dependency(\"{s}\", .{{...}})", .{ name, name });
                @field(context.deps, name) = context.build.dependency(name, .{
                    .target = context.target,
                    .optimize = context.optimize,
                });
            }

            if (@hasField(Spec, "outs")) {
                try @This().setupOutputs(spec.outs, &context);
            }
        }

        /// Configure build outputs based on the .outs spec.
        fn setupOutputs(outs_spec: anytype, context: *Context) !void {
            const Outs = @TypeOf(outs_spec);
            const outs_info = @typeInfo(Outs);

            inline for (outs_info.@"struct".fields) |f| {
                const name = f.name;
                const out_spec = @field(outs_spec, name);
                try @This().setupOutput(name, out_spec, context);
            }
        }

        /// Configure build output from spec found in .outs.
        fn setupOutput(
            name: []const u8,
            out_spec: anytype,
            context: *Context,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const This = @This();
            const Out = @TypeOf(out_spec);
            const allocator = arena.allocator();
            const root_source_file = context.build.path(
                try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{
                    spec.src_path,
                    name,
                }),
            );

            if (@hasField(Out, "gen")) {
                const gen_spec = out_spec.gen;
                const gen_info = @typeInfo(@TypeOf(gen_spec));

                inline for (gen_info.@"struct".fields) |f| {
                    const gen_name = @tagName(@field(out_spec.gen, f.name));

                    if (mem.eql(u8, "exe", gen_name)) {
                        This.setupExe(name, root_source_file, out_spec, context);
                    } else if (mem.eql(u8, "lib", gen_name)) {
                        This.setupLib(name, root_source_file, out_spec, context);
                    } else if (mem.eql(u8, "mod", gen_name)) {
                        This.setupMod(name, root_source_file, out_spec, context);
                    } else if (mem.eql(u8, "unit", gen_name)) {
                        This.setupUnit(root_source_file, out_spec, context);
                    }
                }
            }
        }

        /// Setup executable build output.
        fn setupExe(
            name: []const u8,
            path: std.Build.LazyPath,
            out_spec: anytype,
            context: *Context,
        ) void {
            context.log(
                "artifact = b.addExecutable(.{{.name=\"{s}\", .root_source_file=\"{s}\", ...}})",
                .{ name, path.src_path.sub_path },
            );

            const artifact = context.build.addExecutable(.{
                .name = name,
                .root_source_file = path,
                .target = context.target,
                .optimize = context.optimize,
            });

            @This().setupArtifactDetails(artifact, out_spec, context);
        }

        /// Setup static library build output.
        fn setupLib(
            name: []const u8,
            path: std.Build.LazyPath,
            out_spec: anytype,
            context: *Context,
        ) void {
            context.log(
                "artifact = b.addStaticLibrary(.{{.name=\"{s}\", .root_source_file=\"{s}\", ...}})",
                .{ name, path.src_path.sub_path },
            );

            const artifact = context.build.addStaticLibrary(.{
                .name = name,
                .root_source_file = path,
                .target = context.target,
                .optimize = context.optimize,
            });

            @This().setupArtifactDetails(artifact, out_spec, context);
        }

        /// Setup module export build output.
        fn setupMod(
            name: []const u8,
            path: std.Build.LazyPath,
            out_spec: anytype,
            context: *Context,
        ) void {
            const Out = @TypeOf(out_spec);

            context.log(
                "module = b.addModule(\"{s}\", .{{.root_source_file=\"{s}\", ...}})",
                .{ name, path.src_path.sub_path },
            );

            const module = context.build.addModule(name, .{
                .root_source_file = path,
                .target = context.target,
                .optimize = context.optimize,
            });

            if (@hasField(Out, "zig")) {
                const zig_spec = out_spec.zig;
                const zig_info = @typeInfo(@TypeOf(zig_spec));

                inline for (zig_info.@"struct".fields) |import| {
                    const dep_name = @tagName(@field(zig_spec, import.name));
                    const dep = @field(context.deps, dep_name).?;

                    context.log(
                        "module.addImport(\"{s}\", {s}.module(\"{s}\"))",
                        .{ dep_name, dep_name, dep_name },
                    );
                    module.addImport(dep_name, dep.module(dep_name));
                }
            }
        }

        /// Setup unit test dependency on build output.
        fn setupUnit(
            path: std.Build.LazyPath,
            out_spec: anytype,
            context: *Context,
        ) void {
            const This = @This();
            const Out = @TypeOf(out_spec);

            if (context.build.top_level_steps.get("test")) |test_step| {
                context.log(
                    "artifact = b.addTest(.{{.root_source_file=\"{s}\", ...}})",
                    .{path.src_path.sub_path},
                );
                const artifact = context.build.addTest(.{
                    .root_source_file = path,
                    .target = context.target,
                    .optimize = context.optimize,
                });

                context.log("run_test = b.addRunArtifact(artifact)", .{});
                const run_test = context.build.addRunArtifact(artifact);

                if (@hasField(Out, "sys")) {
                    context.log("artifact.linkLibC()");
                    artifact.linkLibC();
                    This.setupSysLinks(artifact, out_spec.sys, context);
                }

                if (@hasField(Out, "zig")) {
                    This.setupZigImports(artifact, out_spec.zig, context);
                }

                context.log("test_step.step.dependOn(&run_test.step)", .{});
                test_step.step.dependOn(&run_test.step);
            }
        }

        /// Setup static links to C system libraries and module import
        /// dependencies for an artifact.
        fn setupArtifactDetails(
            artifact: *std.Build.Step.Compile,
            out_spec: anytype,
            context: *Context,
        ) void {
            const This = @This();
            const Out = @TypeOf(out_spec);

            if (@hasField(Out, "sys")) {
                context.log("artifact.linkLibC()");
                artifact.linkLibC();
                This.setupSysLinks(artifact, out_spec.sys, context);
            }

            if (@hasField(Out, "zig")) {
                This.setupZigImports(artifact, out_spec.zig, context);
            }

            context.log("b.installArtifact(artifact)", .{});
            context.build.installArtifact(artifact);
        }

        /// Setup build system library links based on build .sys spec.
        fn setupSysLinks(
            artifact: *std.Build.Step.Compile,
            sys_spec: anytype,
            context: *Context,
        ) void {
            const sys_info = @typeInfo(@TypeOf(sys_spec));

            inline for (sys_info.@"struct".fields) |link| {
                const name = @tagName(@field(sys_spec, link.name));
                context.log("artifact.linkSystemLibrary(\"{s}\")", .{name});
                artifact.linkSystemLibrary(name);
            }
        }

        /// Setup Zig imports for an artifact based on build .zig spec.
        fn setupZigImports(
            artifact: *std.Build.Step.Compile,
            zig_spec: anytype,
            context: *Context,
        ) void {
            const zig_info = @typeInfo(@TypeOf(zig_spec));

            inline for (zig_info.@"struct".fields) |import| {
                const name = @tagName(@field(zig_spec, import.name));
                const dep = @field(context.deps, name).?;

                context.log(
                    "artifact.root_module.addImport(\"{s}\", {s}.module(\"{s}\"))",
                    .{ name, name, name },
                );
                artifact.root_module.addImport(name, dep.module(name));
            }
        }
    };
}

/// Type of artifact being produced.
const ArtifactType = enum {
    exe,
    lib,
};

/// Builder for set of dependencies based on build spec.
fn Dependencies(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);
    const Deps = if (@hasField(Spec, "deps")) @TypeOf(spec.deps) else void;
    const deps_info = @typeInfo(Deps);
    const deps_len = if (Deps != void) deps_info.@"struct".fields.len else 0;

    comptime var fields: [deps_len]Type.StructField = undefined;

    if (deps_len > 0) {
        const nul = @typeInfo(Null(*std.Build.Dependency)).@"struct".fields[0].default_value;

        inline for (deps_info.@"struct".fields, 0..) |field, i| {
            const tag = @field(spec.deps, field.name);

            fields[i] = Type.StructField{
                .name = @tagName(tag),
                .type = ?*std.Build.Dependency,
                .alignment = @alignOf(?*std.Build.Dependency),
                .default_value = nul,
                .is_comptime = false,
            };
        }
    }

    return @Type(Type{
        .@"struct" = Type.Struct{
            .layout = .auto,
            .is_tuple = false,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
        },
    });
}

/// This piece of hackery is used to lookup a comptime *const anyopaque that
/// can be used to define StructField with a null default_value.
///
/// In order to obtain the value:
/// @typeInfo(Null(T)).@"struct".fields[0].default_value
fn Null(comptime T: type) type {
    return struct { value: ?T = null };
}

/// Scoped log.
const qb_log = std.log.scoped(.qb);
