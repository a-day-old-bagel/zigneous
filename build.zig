const std = @import("std");

const glfw = @import("lib/mach-glfw/build.zig");
const vkgen = @import("lib/vulkan-zig/generator/index.zig");
const zigvulkan = @import("lib/vulkan-zig/build.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const install_dat_step = b.addInstallDirectory(
        .{ .source_dir = "dat", .install_dir = .{ .custom = "" }, .install_subdir = "bin/dat" },
    );
    b.getInstallStep().dependOn(&install_dat_step.step);

    const exe = b.addExecutable("zigneous", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const gen = vkgen.VkGenerateStep.init(b, "lib/vulkan-zig/examples/vk.xml", "vk.zig");
    exe.addPackage(gen.package);

    exe.addPackagePath("glfw", "lib/mach-glfw/src/main.zig");
    glfw.link(b, exe, .{});

    const res = zigvulkan.ResourceGenStep.init(b, "resources.zig");
    res.addShader("triangle_vert", "dat/triangle.vert");
    res.addShader("triangle_frag", "dat/triangle.frag");
    exe.addPackage(res.package);

    { // Compile HLSL
        const dxc_step = b.step("dxc", "Build HLSL shaders");

        // const dxc_command = makeDxcCmd(
        //     "exampleCompute.hlsl",
        //     "entryPoint",
        //     "output.cs.cso",
        //     "cs",
        //     "PSO__GENERATE_MIPMAPS",
        // );
        // dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

        install_dat_step.step.dependOn(dxc_step);
    }

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

fn makeDxcCmd(
    comptime input_path: []const u8,
    comptime entry_point: []const u8,
    comptime output_filename: []const u8,
    comptime profile: []const u8,
    comptime define: []const u8,
) [9][]const u8 {
    const shader_ver = "6_6";
    const shader_dir = "dat/shaders/";
    return [9][]const u8{
        "dxc",
        input_path,
        "/E " ++ entry_point,
        "/Fo " ++ shader_dir ++ output_filename,
        "/T " ++ profile ++ "_" ++ shader_ver,
        if (define.len == 0) "" else "/D " ++ define,
        "/WX",
        "/Ges",
        "/O3",
    };
}
