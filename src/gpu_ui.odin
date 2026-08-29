package spoticyclint

import "core:mem"
import vk "vendor:vulkan"

VERT_SPV := #load("shaders/ui.vert.spv")
FRAG_SPV := #load("shaders/ui.frag.spv")

Push :: struct {
	inv_screen: [2]f32,
	time:       f32,
}

create_ui_pipeline :: proc(g: ^Gpu) {
	vert := shader_module(g, VERT_SPV)
	frag := shader_module(g, FRAG_SPV)
	defer vk.DestroyShaderModule(g.device, vert, nil)
	defer vk.DestroyShaderModule(g.device, frag, nil)

	stages := [?]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag,
			pName = "main",
		},
	}

	binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(Vertex),
		inputRate = .VERTEX,
	}
	attrs := [?]vk.VertexInputAttributeDescription {
		{location = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{location = 1, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv))},
		{location = 2, format = .R32_UINT, offset = u32(offset_of(Vertex, col))},
		{location = 3, format = .R32_UINT, offset = u32(offset_of(Vertex, tex))},
		{location = 4, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, rect))},
		{location = 5, format = .R32_SFLOAT, offset = u32(offset_of(Vertex, radius))},
		{location = 6, format = .R32_UINT, offset = u32(offset_of(Vertex, effect))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = len(attrs),
		pVertexAttributeDescriptions    = raw_data(attrs[:]),
	}

	assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = MSAA_SAMPLES,
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = raw_data(dynamic_states[:]),
	}

	push_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		size       = size_of(Push),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &g.desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_range,
	}
	vk_check(
		vk.CreatePipelineLayout(g.device, &layout_info, nil, &g.pipeline_layout),
		"CreatePipelineLayout",
	)

	// Dynamic rendering: no render pass or framebuffer objects to keep in sync
	// with the swapchain.
	format := g.format
	rendering := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &format,
	}
	_ = MSAA_SAMPLES
	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = len(stages),
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pColorBlendState    = &blend,
		pDynamicState       = &dynamic_state,
		layout              = g.pipeline_layout,
	}
	vk_check(
		vk.CreateGraphicsPipelines(g.device, 0, 1, &info, nil, &g.pipeline),
		"CreateGraphicsPipelines",
	)
}

@(private = "file")
shader_module :: proc(g: ^Gpu, spv: []byte) -> vk.ShaderModule {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spv),
		pCode    = cast(^u32)raw_data(spv),
	}
	module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(g.device, &info, nil, &module), "CreateShaderModule")
	return module
}

// Uploads this frame's geometry and submits it. Returns false when the
// swapchain needs rebuilding.
gpu_draw :: proc(g: ^Gpu, ui: ^UI, clear_color: Color) -> bool {
	f := &g.frames[g.frame_index]
	vk.WaitForFences(g.device, 1, &f.fence, true, max(u64))

	image_index: u32
	res := vk.AcquireNextImageKHR(
		g.device,
		g.swapchain,
		max(u64),
		f.acquire,
		0,
		&image_index,
	)
	if res == .ERROR_OUT_OF_DATE_KHR do return false
	if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		vk_check(res, "AcquireNextImageKHR")
	}
	vk.ResetFences(g.device, 1, &f.fence)

	vbytes := len(ui.verts) * size_of(Vertex)
	ibytes := len(ui.indices) * size_of(u32)
	if vbytes > VERTEX_BYTES || ibytes > INDEX_BYTES do return true // skip a too-big frame
	if vbytes > 0 do mem.copy(f.vmapped, raw_data(ui.verts), vbytes)
	if ibytes > 0 do mem.copy(f.imapped, raw_data(ui.indices), ibytes)

	cmd := f.cmd
	vk.ResetCommandBuffer(cmd, {})
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin)

	swap_barrier(cmd, g.images[image_index], .UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL)

	// Premultiplied, to match the composite mode the swapchain asked for.
	alpha := f32((u32(clear_color) >> 24) & 0xff) / 255
	c := [4]f32 {
		f32(u32(clear_color) & 0xff) / 255 * alpha,
		f32((u32(clear_color) >> 8) & 0xff) / 255 * alpha,
		f32((u32(clear_color) >> 16) & 0xff) / 255 * alpha,
		alpha,
	}
	// Render into the multisampled image and resolve straight into the
	// swapchain image; the MSAA contents themselves are never needed again.
	attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = g.msaa_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		resolveMode = {.AVERAGE},
		resolveImageView = g.views[image_index],
		resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {color = {float32 = c}},
	}
	rendering := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = {extent = g.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attachment,
	}
	vk.CmdBeginRendering(cmd, &rendering)

	vk.CmdBindPipeline(cmd, .GRAPHICS, g.pipeline)
	// The one and only descriptor set: bound once, never rebound.
	desc_set := g.desc_set
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g.pipeline_layout, 0, 1, &desc_set, 0, nil)

	viewport := vk.Viewport {
		width    = f32(g.extent.width),
		height   = f32(g.extent.height),
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	// Vertices arrive in logical units; fold the HiDPI scale in here so the
	// UI code never has to know about it.
	push := Push {
		inv_screen = {g.ui_scale / f32(g.extent.width), g.ui_scale / f32(g.extent.height)},
		time = ui.time,
	}
	vk.CmdPushConstants(cmd, g.pipeline_layout, {.VERTEX}, 0, size_of(Push), &push)

	if len(ui.indices) > 0 {
		offset: vk.DeviceSize = 0
		vbuf := f.vbuf
		vk.CmdBindVertexBuffers(cmd, 0, 1, &vbuf, &offset)
		vk.CmdBindIndexBuffer(cmd, f.ibuf, 0, .UINT32)

		for dc in ui.cmds {
			if dc.index_count == 0 do continue
			scissor := vk.Rect2D {
				offset = {
					i32(max(dc.clip.x, 0) * g.ui_scale),
					i32(max(dc.clip.y, 0) * g.ui_scale),
				},
				extent = {
					u32(max(dc.clip.w, 0) * g.ui_scale),
					u32(max(dc.clip.h, 0) * g.ui_scale),
				},
			}
			vk.CmdSetScissor(cmd, 0, 1, &scissor)
			vk.CmdDrawIndexed(cmd, dc.index_count, 1, dc.index_offset, 0, 0)
		}
	}

	vk.CmdEndRendering(cmd)
	swap_barrier(cmd, g.images[image_index], .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)
	vk.EndCommandBuffer(cmd)

	wait := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = f.acquire,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = g.present_sems[image_index],
		stageMask = {.ALL_GRAPHICS},
	}
	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal,
	}
	vk_check(vk.QueueSubmit2(g.queue, 1, &submit, f.fence), "QueueSubmit2")

	present_sem := g.present_sems[image_index]
	swapchain := g.swapchain
	image := image_index
	present := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &present_sem,
		swapchainCount     = 1,
		pSwapchains        = &swapchain,
		pImageIndices      = &image,
	}
	pres := vk.QueuePresentKHR(g.queue, &present)
	g.frame_index = (g.frame_index + 1) % MAX_FRAMES

	return pres != .ERROR_OUT_OF_DATE_KHR && pres != .SUBOPTIMAL_KHR
}

@(private = "file")
swap_barrier :: proc(cmd: vk.CommandBuffer, image: vk.Image, from, to: vk.ImageLayout) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		oldLayout = from,
		newLayout = to,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if to == .COLOR_ATTACHMENT_OPTIMAL {
		barrier.srcStageMask = {.TOP_OF_PIPE}
		barrier.dstStageMask = {.COLOR_ATTACHMENT_OUTPUT}
		barrier.dstAccessMask = {.COLOR_ATTACHMENT_WRITE}
	} else {
		barrier.srcStageMask = {.COLOR_ATTACHMENT_OUTPUT}
		barrier.srcAccessMask = {.COLOR_ATTACHMENT_WRITE}
		barrier.dstStageMask = {.BOTTOM_OF_PIPE}
	}
	info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &info)
}
