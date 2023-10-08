const std = @import("std");

const zsdl = @import("lib/zsdl/build.zig");
const vkgen = @import("lib/vulkan-zig/generator/index.zig");
const zigvulkan = @import("lib/vulkan-zig/build.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "Zigneous_Example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    // if (exe.optimize != .Debug) exe.want_lto = false; // Problems with LTO in Release modes on Windows.
    b.installArtifact(exe);

    // vulkan-zig
    const gen = vkgen.VkGenerateStep.create(b, "lib/vulkan-zig/examples/vk.xml");
    exe.addModule("vulkan", gen.getModule());

    // zsdl
    const zsdl_pkg = zsdl.package(b, target, optimize, .{});
    zsdl_pkg.link(exe);

    // shaders, to be compiled using glslc
    const shader_comp = vkgen.ShaderCompileStep.create(b, &[_][]const u8{"glslc", "--target-env=vulkan1.2"}, "-o");
    shader_comp.add("triangle_frag", "dat/triangle.frag", .{});
    shader_comp.add("triangle_vert", "dat/triangle.vert", .{});
    exe.addModule("shaders", shader_comp.getModule());

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .name = "main test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
