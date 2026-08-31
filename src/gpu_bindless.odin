package spoticyclint

import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"

// Every texture the UI can draw lives in one descriptor array, so nothing
// between draws ever has to rebind a descriptor set: a glyph, a panel and an
// album cover differ only by an integer in the vertex data.
BINDLESS_CAPACITY :: 1024

// Set once the device is up: whether covers can be kept as BC1 blocks all the
// way from the disk cache into VRAM. Read from the art threads, written once
// before they start.
g_bc1_ok: bool

FONT_TEX :: 0 // slot 0 is always the glyph atlas
WHITE_TEX :: 1 // slot 1 is always a 1x1 opaque white pixel

Texture :: struct {
	image:  vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
	width:  int,
	height: int,
}

bindless_full :: proc(g: ^Gpu) -> bool {
	return len(g.textures) >= BINDLESS_CAPACITY
}

bindless_init :: proc(g: ^Gpu) {
	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = vk.LOD_CLAMP_NONE,
	}
	vk_check(vk.CreateSampler(g.device, &sampler_info, nil, &g.sampler), "CreateSampler")

	// Covers are kept compressed if the GPU can sample them that way, which on
	// anything desktop it can. Without it they stay RGBA and simply cost more.
	props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(g.phys, .BC1_RGB_UNORM_BLOCK, &props)
	g_bc1_ok = .SAMPLED_IMAGE in props.optimalTilingFeatures

	binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = BINDLESS_CAPACITY,
		stageFlags      = {.FRAGMENT},
	}
	// PARTIALLY_BOUND: most slots are empty and the shader never reads them.
	// UPDATE_AFTER_BIND: album art can land in the table while the set is bound.
	// VARIABLE_DESCRIPTOR_COUNT: pay for the slots we allocate, not the cap.
	binding_flags := vk.DescriptorBindingFlags{
		.PARTIALLY_BOUND,
		.UPDATE_AFTER_BIND,
		.VARIABLE_DESCRIPTOR_COUNT,
	}
	flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = 1,
		pBindingFlags = &binding_flags,
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = 1,
		pBindings    = &binding,
	}
	vk_check(
		vk.CreateDescriptorSetLayout(g.device, &layout_info, nil, &g.desc_layout),
		"CreateDescriptorSetLayout",
	)

	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = BINDLESS_CAPACITY,
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	vk_check(
		vk.CreateDescriptorPool(g.device, &pool_info, nil, &g.desc_pool),
		"CreateDescriptorPool",
	)

	count: u32 = BINDLESS_CAPACITY
	count_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts  = &count,
	}
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &count_info,
		descriptorPool     = g.desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &g.desc_layout,
	}
	vk_check(
		vk.AllocateDescriptorSets(g.device, &alloc_info, &g.desc_set),
		"AllocateDescriptorSets",
	)
}

// What the bytes handed to an upload actually are.
Tex_Kind :: enum {
	Coverage, // one byte a pixel, drawn as alpha — glyphs
	Color, // RGBA
	Blocks, // BC1, four bytes a 4x4 block, sampled by the GPU as it is
}

// Uploads pixels and returns the slot the shader should index. `channels` is
// 1 (coverage, drawn as alpha) or 4 (RGBA).
texture_upload :: proc(g: ^Gpu, pixels: []byte, width, height, channels: int) -> u32 {
	up := Upload {
		data   = pixels,
		width  = width,
		height = height,
		kind   = channels == 1 ? .Coverage : .Color,
	}
	ups := []Upload{up}
	texture_upload_many(g, ups)
	return ups[0].slot
}

// Covers arrive as BC1 blocks, straight off disk in the form the sampler
// wants. See bc1.odin.
texture_upload_bc1 :: proc(g: ^Gpu, blocks: []byte, width, height: int) -> u32 {
	up := Upload {
		data   = blocks,
		width  = width,
		height = height,
		kind   = .Blocks,
	}
	ups := []Upload{up}
	texture_upload_many(g, ups)
	return ups[0].slot
}

Upload :: struct {
	data:   []byte,
	width:  int,
	height: int,
	kind:   Tex_Kind,
	slot:   u32, // filled in
}

// Every upload used to be its own submit and its own fence wait, so a frame
// that had a screenful of covers ready paid that round trip a few dozen times
// and had to be rationed to four a frame. The copies all go in one command
// buffer now and the whole batch costs a single wait.
texture_upload_many :: proc(g: ^Gpu, ups: []Upload) {
	if len(ups) == 0 do return

	cmd := begin_one_shot(g)
	staging := make([][2]u64, len(ups), context.temp_allocator)
	n := 0

	for &up in ups {
		if len(g.textures) >= BINDLESS_CAPACITY {
			up.slot = WHITE_TEX
			continue
		}
		tex, buf, mem := stage_texture(g, cmd, up.data, up.width, up.height, up.kind)
		up.slot = u32(len(g.textures))
		append(&g.textures, tex)
		write_texture_descriptor(g, up.slot)
		staging[n] = {u64(buf), u64(mem)}
		n += 1
	}

	end_one_shot(g, cmd)
	for s in staging[:n] {
		vk.DestroyBuffer(g.device, vk.Buffer(s[0]), nil)
		vk.FreeMemory(g.device, vk.DeviceMemory(s[1]), nil)
	}
}

@(private = "file")
write_texture_descriptor :: proc(g: ^Gpu, slot: u32) {
	desc_image := vk.DescriptorImageInfo {
		sampler     = g.sampler,
		imageView   = g.textures[slot].view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = g.desc_set,
		dstBinding      = 0,
		dstArrayElement = slot,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &desc_image,
	}
	vk.UpdateDescriptorSets(g.device, 1, &write, 0, nil)
}

// Creates the image and records its copy into `cmd`. The staging buffer it
// returns has to outlive the submit, so the caller frees it after the wait.
@(private = "file")
stage_texture :: proc(
	g: ^Gpu,
	cmd: vk.CommandBuffer,
	pixels: []byte,
	width, height: int,
	kind: Tex_Kind,
) -> (
	tex: Texture,
	staging: vk.Buffer,
	staging_mem: vk.DeviceMemory,
) {
	format: vk.Format
	switch kind {
	case .Coverage:
		format = .R8_UNORM
	case .Color:
		format = .R8G8B8A8_UNORM
	case .Blocks:
		format = .BC1_RGB_UNORM_BLOCK
	}
	tex = Texture {
		width  = width,
		height = height,
	}

	img_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = {u32(width), u32(height), 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.TRANSFER_DST, .SAMPLED},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(g.device, &img_info, nil, &tex.image), "CreateImage")

	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g.device, tex.image, &req)
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(g, req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(g.device, &alloc, nil, &tex.memory), "AllocateMemory")
	vk.BindImageMemory(g.device, tex.image, tex.memory, 0)

	staging_ptr: rawptr
	staging, staging_mem, staging_ptr = create_mapped_buffer(
		g,
		vk.DeviceSize(len(pixels)),
		{.TRANSFER_SRC},
	)
	mem.copy(staging_ptr, raw_data(pixels), len(pixels))

	image_barrier(cmd, tex.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = {u32(width), u32(height), 1},
	}
	vk.CmdCopyBufferToImage(cmd, staging, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	image_barrier(cmd, tex.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

	// A single-channel texture is coverage: broadcast it to alpha and leave
	// RGB white, so the one shader path handles glyphs and images alike. BC1
	// carries no alpha of its own and reads back as opaque.
	swizzle := vk.ComponentMapping{.R, .G, .B, .A}
	if kind == .Coverage do swizzle = {.ONE, .ONE, .ONE, .R}
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = format,
		components = swizzle,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_check(vk.CreateImageView(g.device, &view_info, nil, &tex.view), "CreateImageView")
	return
}

// Swaps new pixels into an existing slot, so a texture that is replaced often —
// the feature cover, at full size — costs one entry rather than one per track.
texture_replace :: proc(g: ^Gpu, slot: u32, pixels: []byte, width, height: int, kind: Tex_Kind) {
	if int(slot) >= len(g.textures) do return

	// The old image may still be referenced by a frame in flight. Replacing it
	// happens once per track, so waiting is cheaper than tracking lifetimes.
	vk.DeviceWaitIdle(g.device)

	old := g.textures[slot]
	vk.DestroyImageView(g.device, old.view, nil)
	vk.DestroyImage(g.device, old.image, nil)
	vk.FreeMemory(g.device, old.memory, nil)

	cmd := begin_one_shot(g)
	tex, buf, mem := stage_texture(g, cmd, pixels, width, height, kind)
	end_one_shot(g, cmd)
	vk.DestroyBuffer(g.device, buf, nil)
	vk.FreeMemory(g.device, mem, nil)

	g.textures[slot] = tex
	write_texture_descriptor(g, slot)
}

@(private = "file")
image_barrier :: proc(cmd: vk.CommandBuffer, image: vk.Image, from, to: vk.ImageLayout) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		oldLayout = from,
		newLayout = to,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	switch {
	case from == .UNDEFINED && to == .TRANSFER_DST_OPTIMAL:
		barrier.srcStageMask = {.TOP_OF_PIPE}
		barrier.dstStageMask = {.COPY}
		barrier.dstAccessMask = {.TRANSFER_WRITE}
	case from == .TRANSFER_DST_OPTIMAL && to == .SHADER_READ_ONLY_OPTIMAL:
		barrier.srcStageMask = {.COPY}
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstStageMask = {.FRAGMENT_SHADER}
		barrier.dstAccessMask = {.SHADER_SAMPLED_READ}
	}
	info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &info)
}

@(private = "file")
begin_one_shot :: proc(g: ^Gpu) -> vk.CommandBuffer {
	cmd: vk.CommandBuffer
	alloc := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = g.cmd_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	vk.AllocateCommandBuffers(g.device, &alloc, &cmd)
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin)
	return cmd
}

@(private = "file")
end_one_shot :: proc(g: ^Gpu, cmd: vk.CommandBuffer) {
	cmd := cmd
	vk.EndCommandBuffer(cmd)
	submit := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}

	// Wait on a fence for this copy alone. QueueWaitIdle would also wait for
	// the frame already in flight, which is gated on vsync — that turned a
	// sub-millisecond texture upload into a 13ms stall.
	fence: vk.Fence
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	vk_check(vk.CreateFence(g.device, &fence_info, nil, &fence), "CreateFence (upload)")

	vk.QueueSubmit(g.queue, 1, &submit, fence)
	vk.WaitForFences(g.device, 1, &fence, true, max(u64))

	vk.DestroyFence(g.device, fence, nil)
	vk.FreeCommandBuffers(g.device, g.cmd_pool, 1, &cmd)
}

bindless_destroy :: proc(g: ^Gpu) {
	for t in g.textures {
		vk.DestroyImageView(g.device, t.view, nil)
		vk.DestroyImage(g.device, t.image, nil)
		vk.FreeMemory(g.device, t.memory, nil)
	}
	delete(g.textures)
	vk.DestroyDescriptorPool(g.device, g.desc_pool, nil)
	vk.DestroyDescriptorSetLayout(g.device, g.desc_layout, nil)
	vk.DestroySampler(g.device, g.sampler, nil)
}
