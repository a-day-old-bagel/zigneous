const std = @import("std");
const vk = @import("vulkan");
// const glfw = @import("glfw");
const shaders = @import("shaders");
const PlatformContext = @import("platform_context.zig").PlatformContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const Allocator = std.mem.Allocator;

const app_name = "Zigneous";

const Vertex = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

pub fn main() !void {

    const allocator = std.heap.page_allocator;

    var pc = try PlatformContext.init(allocator, app_name);
    defer pc.deinit();

    std.debug.print("Using device: {s}\n", .{pc.deviceName()});

    var swapchain = try Swapchain.init(allocator, &pc);
    defer swapchain.deinit();

    const pipeline_layout = try pc.vkd.createPipelineLayout(pc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer pc.vkd.destroyPipelineLayout(pc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(&pc, swapchain);
    defer pc.vkd.destroyRenderPass(pc.dev, render_pass, null);

    var pipeline = try createPipeline(&pc, pipeline_layout, render_pass);
    defer pc.vkd.destroyPipeline(pc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&pc, allocator, render_pass, swapchain);
    defer destroyFramebuffers(&pc, allocator, framebuffers);

    const pool = try pc.vkd.createCommandPool(pc.dev, &.{
        .flags = .{},
        .queue_family_index = pc.graphics_queue.family,
    }, null);
    defer pc.vkd.destroyCommandPool(pc.dev, pool, null);

    const buffer = try pc.vkd.createBuffer(pc.dev, &.{
        .flags = .{},
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer pc.vkd.destroyBuffer(pc.dev, buffer, null);
    const mem_reqs = pc.vkd.getBufferMemoryRequirements(pc.dev, buffer);
    const memory = try pc.allocate(mem_reqs, .{ .device_local_bit = true });
    defer pc.vkd.freeMemory(pc.dev, memory, null);
    try pc.vkd.bindBufferMemory(pc.dev, buffer, memory, 0);

    try uploadVertices(&pc, pool, buffer);

    var cmdbufs = try createCommandBuffers(
        &pc,
        pool,
        allocator,
        buffer,
        swapchain.extent,
        render_pass,
        pipeline,
        framebuffers,
    );
    defer destroyCommandBuffers(&pc, pool, allocator, cmdbufs);

    for (0..600) |_| {
        const cmdbuf = cmdbufs[swapchain.image_index];

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal) {
            var current_width: i32 = -1;
            var current_height: i32 = -1;
            try pc.sdl_window.getSize(&current_width, &current_height);
            if (current_width > 0 and current_height > 0) {
                pc.extent.width = @as(u32, @intCast(current_width));
                pc.extent.height = @as(u32, @intCast(current_height));
            }
            try swapchain.recreate();

            destroyFramebuffers(&pc, allocator, framebuffers);
            framebuffers = try createFramebuffers(&pc, allocator, render_pass, swapchain);

            destroyCommandBuffers(&pc, pool, allocator, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &pc,
                pool,
                allocator,
                buffer,
                swapchain.extent,
                render_pass,
                pipeline,
                framebuffers,
            );
        }
    }

    try swapchain.waitForAllFences();
}

fn uploadVertices(pc: *const PlatformContext, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    const staging_buffer = try pc.vkd.createBuffer(pc.dev, &.{
        .flags = .{},
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer pc.vkd.destroyBuffer(pc.dev, staging_buffer, null);
    const mem_reqs = pc.vkd.getBufferMemoryRequirements(pc.dev, staging_buffer);
    const staging_memory = try pc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer pc.vkd.freeMemory(pc.dev, staging_memory, null);
    try pc.vkd.bindBufferMemory(pc.dev, staging_buffer, staging_memory, 0);

    {
        const data = try pc.vkd.mapMemory(pc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer pc.vkd.unmapMemory(pc.dev, staging_memory);

        const gpu_vertices = @as([*]Vertex, @alignCast(@ptrCast(data)));
        for (vertices, 0..) |vertex, i| {
            gpu_vertices[i] = vertex;
        }
    }

    try copyBuffer(pc, pool, buffer, staging_buffer, @sizeOf(@TypeOf(vertices)));
}

fn copyBuffer(pc: *const PlatformContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try pc.vkd.allocateCommandBuffers(pc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @as([*]vk.CommandBuffer, @ptrCast(&cmdbuf)));
    defer pc.vkd.freeCommandBuffers(pc.dev, pool, 1, @as([*]const vk.CommandBuffer, @ptrCast(&cmdbuf)));

    try pc.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    pc.vkd.cmdCopyBuffer(cmdbuf, src, dst, 1, @as([*]const vk.BufferCopy, @ptrCast(&region)));

    try pc.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @as([*]const vk.CommandBuffer, @ptrCast(&cmdbuf)),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try pc.vkd.queueSubmit(pc.graphics_queue.handle, 1, @as([*]const vk.SubmitInfo, @ptrCast(&si)), .null_handle);
    try pc.vkd.queueWaitIdle(pc.graphics_queue.handle);
}

fn createCommandBuffers(
    pc: *const PlatformContext,
    pool: vk.CommandPool,
    allocator: Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer allocator.free(cmdbufs);

    try pc.vkd.allocateCommandBuffers(pc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @as(u32, @truncate(cmdbufs.len)),
    }, cmdbufs.ptr);
    errdefer pc.vkd.freeCommandBuffers(pc.dev, pool, @as(u32, @truncate(cmdbufs.len)), cmdbufs.ptr);

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(extent.width)),
        .height = @as(f32, @floatFromInt(extent.height)),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    for (cmdbufs, 0..) |cmdbuf, i| {
        try pc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{},
            .p_inheritance_info = null,
        });

        pc.vkd.cmdSetViewport(cmdbuf, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));
        pc.vkd.cmdSetScissor(cmdbuf, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor)));

        // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        pc.vkd.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffers[i],
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @as([*]const vk.ClearValue, @ptrCast(&clear)),
        }, .@"inline");

        pc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);
        const offset = [_]vk.DeviceSize{0};
        pc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @as([*]const vk.Buffer, @ptrCast(&buffer)), &offset);
        pc.vkd.cmdDraw(cmdbuf, vertices.len, 1, 0, 0);

        pc.vkd.cmdEndRenderPass(cmdbuf);
        try pc.vkd.endCommandBuffer(cmdbuf);
    }

    return cmdbufs;
}

fn destroyCommandBuffers(pc: *const PlatformContext, pool: vk.CommandPool, allocator: Allocator, cmdbufs: []vk.CommandBuffer) void {
    pc.vkd.freeCommandBuffers(pc.dev, pool, @as(u32, @truncate(cmdbufs.len)), cmdbufs.ptr);
    allocator.free(cmdbufs);
}

fn createFramebuffers(pc: *const PlatformContext, allocator: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| pc.vkd.destroyFramebuffer(pc.dev, fb, null);

    for (framebuffers) |*fb| {
        fb.* = try pc.vkd.createFramebuffer(pc.dev, &.{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @as([*]const vk.ImageView, @ptrCast(&swapchain.swap_images[i].view)),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(pc: *const PlatformContext, allocator: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| pc.vkd.destroyFramebuffer(pc.dev, fb, null);
    allocator.free(framebuffers);
}

fn createRenderPass(pc: *const PlatformContext, swapchain: Swapchain) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @as([*]const vk.AttachmentReference, @ptrCast(&color_attachment_ref)),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    return try pc.vkd.createRenderPass(pc.dev, &.{
        .flags = .{},
        .attachment_count = 1,
        .p_attachments = @as([*]const vk.AttachmentDescription, @ptrCast(&color_attachment)),
        .subpass_count = 1,
        .p_subpasses = @as([*]const vk.SubpassDescription, @ptrCast(&subpass)),
        .dependency_count = 0,
        .p_dependencies = undefined,
    }, null);
}

fn createPipeline(
    pc: *const PlatformContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
) !vk.Pipeline {
    const vert = try pc.vkd.createShaderModule(pc.dev, &.{
        .flags = .{},
        .code_size = shaders.triangle_vert.len,
        .p_code = @as([*]const u32, @alignCast(@ptrCast(&shaders.triangle_vert))),
    }, null);
    defer pc.vkd.destroyShaderModule(pc.dev, vert, null);

    const frag = try pc.vkd.createShaderModule(pc.dev, &.{
        .flags = .{},
        .code_size = shaders.triangle_frag.len,
        .p_code = @as([*]const u32, @alignCast(@ptrCast(&shaders.triangle_frag))),
    }, null);
    defer pc.vkd.destroyShaderModule(pc.dev, frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @as([*]const vk.VertexInputBindingDescription, @ptrCast(&Vertex.binding_description)),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
    };

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
        .scissor_count = 1,
        .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @as([*]const vk.PipelineColorBlendAttachmentState, @ptrCast(&pcbas)),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try pc.vkd.createGraphicsPipelines(
        pc.dev,
        .null_handle,
        1,
        @as([*]const vk.GraphicsPipelineCreateInfo, @ptrCast(&gpci)),
        null,
        @as([*]vk.Pipeline, @ptrCast(&pipeline)),
    );
    return pipeline;
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
