package spoticyclint

import "core:dynlib"
import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

MAX_FRAMES :: 2
MSAA_SAMPLES :: vk.SampleCountFlags{._4}

Frame :: struct {
	cmd:        vk.CommandBuffer,
	fence:      vk.Fence,
	acquire:    vk.Semaphore,
	vbuf:       vk.Buffer,
	vmem:       vk.DeviceMemory,
	vmapped:    [^]byte,
	ibuf:       vk.Buffer,
	imem:       vk.DeviceMemory,
	imapped:    [^]byte,
}

Gpu :: struct {
	instance:        vk.Instance,
	phys:            vk.PhysicalDevice,
	device:          vk.Device,
	queue:           vk.Queue,
	queue_family:    u32,
	surface:         vk.SurfaceKHR,

	swapchain:       vk.SwapchainKHR,
	format:          vk.Format,
	extent:          vk.Extent2D,
	images:          []vk.Image,
	views:           []vk.ImageView,
	present_sems:    []vk.Semaphore,

	cmd_pool:        vk.CommandPool,
	frames:          [MAX_FRAMES]Frame,
	frame_index:     int,

	// Bindless table (see gpu_bindless.odin).
	sampler:         vk.Sampler,
	desc_pool:       vk.DescriptorPool,
	desc_layout:     vk.DescriptorSetLayout,
	desc_set:        vk.DescriptorSet,
	textures:        [dynamic]Texture,

	// Framebuffer pixels per logical UI unit, from the compositor.
	ui_scale:        f32,

	// 4x multisampled target. Rounded rects anti-alias themselves in the
	// shader, but the triangles in the transport icons cannot, and jagged play
	// buttons are the first thing you notice. The cost is irrelevant when the
	// UI only redraws on change.
	msaa_image:      vk.Image,
	msaa_memory:     vk.DeviceMemory,
	msaa_view:       vk.ImageView,

	pipeline_layout: vk.PipelineLayout,
	pipeline:        vk.Pipeline,
}

VERTEX_BYTES :: 1 << 20
INDEX_BYTES :: 1 << 19

vk_check :: proc(res: vk.Result, what: string, loc := #caller_location) {
	if res != .SUCCESS {
		fmt.eprintfln("vulkan: %s failed: %v (%v)", what, res, loc)
		os.exit(1)
	}
}

gpu_init :: proc(g: ^Gpu, w: ^Window) -> bool {
	lib, lib_ok := dynlib.load_library("libvulkan.so.1")
	if !lib_ok {
		fmt.eprintln("libvulkan.so.1 not found")
		return false
	}
	gipa, _ := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	vk.load_proc_addresses_global(gipa)

	create_instance(g)
	vk.load_proc_addresses_instance(g.instance)
	when ODIN_DEBUG do create_debug_messenger(g)

	surface_info := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = cast(^vk.wl_display)rawptr(w.display),
		surface = cast(^vk.wl_surface)rawptr(w.surface),
	}
	vk_check(
		vk.CreateWaylandSurfaceKHR(g.instance, &surface_info, nil, &g.surface),
		"CreateWaylandSurfaceKHR",
	)

	if !pick_physical_device(g) do return false
	create_device(g)
	vk.load_proc_addresses_device(g.device)
	vk.GetDeviceQueue(g.device, g.queue_family, 0, &g.queue)

	g.ui_scale = f32(w.scale)
	pw, ph := window_pixel_size(w)
	create_swapchain(g, u32(pw), u32(ph))
	create_frames(g)
	bindless_init(g)
	create_ui_pipeline(g)
	return true
}

@(private = "file")
create_instance :: proc(g: ^Gpu) {
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "spoticyclint",
		apiVersion       = vk.API_VERSION_1_3,
	}
	exts := [?]cstring {
		vk.KHR_SURFACE_EXTENSION_NAME,
		vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME,
		vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
	}
	layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}

	info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app,
		enabledExtensionCount   = len(exts) - 1,
		ppEnabledExtensionNames = raw_data(exts[:]),
	}
	when ODIN_DEBUG {
		info.enabledExtensionCount = len(exts)
		if validation_layer_available() {
			info.enabledLayerCount = len(layers)
			info.ppEnabledLayerNames = raw_data(layers[:])
		}
	}
	vk_check(vk.CreateInstance(&info, nil, &g.instance), "CreateInstance")
}

@(private = "file")
debug_messenger: vk.DebugUtilsMessengerEXT

@(private = "file")
create_debug_messenger :: proc(g: ^Gpu) {
	if vk.CreateDebugUtilsMessengerEXT == nil do return
	info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = proc "system" (
			severity: vk.DebugUtilsMessageSeverityFlagsEXT,
			types: vk.DebugUtilsMessageTypeFlagsEXT,
			data: ^vk.DebugUtilsMessengerCallbackDataEXT,
			user_data: rawptr,
		) -> b32 {
			context = g_ctx
			fmt.eprintfln("vulkan %v: %s", severity, data.pMessage)
			return false
		},
	}
	vk.CreateDebugUtilsMessengerEXT(g.instance, &info, nil, &debug_messenger)
}

@(private = "file")
validation_layer_available :: proc() -> bool {
	n: u32
	vk.EnumerateInstanceLayerProperties(&n, nil)
	props := make([]vk.LayerProperties, n, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&n, raw_data(props))
	for &p in props {
		if string(cstring(&p.layerName[0])) == "VK_LAYER_KHRONOS_validation" do return true
	}
	return false
}

@(private = "file")
pick_physical_device :: proc(g: ^Gpu) -> bool {
	n: u32
	vk.EnumeratePhysicalDevices(g.instance, &n, nil)
	devs := make([]vk.PhysicalDevice, n, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g.instance, &n, raw_data(devs))

	best_score := -1
	for d in devs {
		idx, has_queue := find_present_queue(g, d)
		if !has_queue do continue
		if !supports_bindless(d) do continue

		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(d, &props)
		score := props.deviceType == .DISCRETE_GPU ? 2 : 1
		if score > best_score {
			best_score = score
			g.phys = d
			g.queue_family = idx
		}
	}
	if best_score < 0 {
		fmt.eprintln("no Vulkan device with bindless (descriptor indexing) support")
		return false
	}
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.phys, &props)
	fmt.printfln("GPU: %s", string(cstring(&props.deviceName[0])))
	return true
}

@(private = "file")
find_present_queue :: proc(g: ^Gpu, d: vk.PhysicalDevice) -> (u32, bool) {
	n: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &n, nil)
	fams := make([]vk.QueueFamilyProperties, n, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &n, raw_data(fams))
	for f, i in fams {
		if .GRAPHICS not_in f.queueFlags do continue
		support: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(d, u32(i), g.surface, &support)
		if support do return u32(i), true
	}
	return 0, false
}

@(private = "file")
supports_bindless :: proc(d: vk.PhysicalDevice) -> bool {
	di := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
	}
	v13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext = &di,
	}
	f2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &v13,
	}
	vk.GetPhysicalDeviceFeatures2(d, &f2)
	return(
		bool(di.runtimeDescriptorArray) &&
		bool(di.descriptorBindingPartiallyBound) &&
		bool(di.shaderSampledImageArrayNonUniformIndexing) &&
		bool(di.descriptorBindingSampledImageUpdateAfterBind) &&
		bool(di.descriptorBindingVariableDescriptorCount) &&
		bool(v13.dynamicRendering) &&
		bool(v13.synchronization2) \
	)
}

@(private = "file")
create_device :: proc(g: ^Gpu) {
	priority: f32 = 1
	qinfo := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = g.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	exts := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

	di := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType                                     = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
		runtimeDescriptorArray                    = true,
		descriptorBindingPartiallyBound           = true,
		shaderSampledImageArrayNonUniformIndexing = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
		descriptorBindingVariableDescriptorCount  = true,
	}
	v13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &di,
		dynamicRendering = true,
		synchronization2 = true,
	}
	f2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &v13,
	}

	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &f2,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &qinfo,
		enabledExtensionCount   = len(exts),
		ppEnabledExtensionNames = raw_data(exts[:]),
	}
	vk_check(vk.CreateDevice(g.phys, &info, nil, &g.device), "CreateDevice")
}

create_swapchain :: proc(g: ^Gpu, width, height: u32) {
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.phys, g.surface, &caps)

	n: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.phys, g.surface, &n, nil)
	formats := make([]vk.SurfaceFormatKHR, n, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.phys, g.surface, &n, raw_data(formats))

	chosen := formats[0]
	for f in formats {
		if f.format == .B8G8R8A8_UNORM && f.colorSpace == .SRGB_NONLINEAR {
			chosen = f
			break
		}
	}
	g.format = chosen.format

	g.extent = caps.currentExtent
	if g.extent.width == max(u32) {
		g.extent = {
			clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
			clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
		}
	}
	if g.extent.width == 0 do g.extent.width = 1
	if g.extent.height == 0 do g.extent.height = 1

	// Prefer mailbox: with FIFO, acquiring the next image blocks for a whole
	// vsync interval before we get to look at input again, which is felt as
	// lag on every click. Mailbox lets us pick up input immediately.
	present_mode := vk.PresentModeKHR.FIFO
	mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.phys, g.surface, &mode_count, nil)
	modes := make([]vk.PresentModeKHR, mode_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.phys, g.surface, &mode_count, raw_data(modes))
	for m in modes {
		if m == .MAILBOX {
			present_mode = .MAILBOX
			break
		}
	}

	count := caps.minImageCount + 1
	if present_mode == .MAILBOX do count = max(count, 3)
	if caps.maxImageCount > 0 do count = min(count, caps.maxImageCount)

	old := g.swapchain
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = g.surface,
		minImageCount    = count,
		imageFormat      = g.format,
		imageColorSpace  = chosen.colorSpace,
		imageExtent      = g.extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	vk_check(vk.CreateSwapchainKHR(g.device, &info, nil, &g.swapchain), "CreateSwapchainKHR")
	if old != 0 {
		destroy_swapchain_views(g)
		vk.DestroySwapchainKHR(g.device, old, nil)
	}

	vk.GetSwapchainImagesKHR(g.device, g.swapchain, &n, nil)
	g.images = make([]vk.Image, n)
	vk.GetSwapchainImagesKHR(g.device, g.swapchain, &n, raw_data(g.images))

	g.views = make([]vk.ImageView, n)
	g.present_sems = make([]vk.Semaphore, n)
	for img, i in g.images {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = img,
			viewType = .D2,
			format = g.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk_check(vk.CreateImageView(g.device, &view_info, nil, &g.views[i]), "CreateImageView")

		sem_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(
			vk.CreateSemaphore(g.device, &sem_info, nil, &g.present_sems[i]),
			"CreateSemaphore",
		)
	}

	create_msaa_target(g)
}

@(private = "file")
create_msaa_target :: proc(g: ^Gpu) {
	destroy_msaa_target(g)

	info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = g.format,
		extent = {g.extent.width, g.extent.height, 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = MSAA_SAMPLES,
		tiling = .OPTIMAL,
		usage = {.COLOR_ATTACHMENT, .TRANSIENT_ATTACHMENT},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(g.device, &info, nil, &g.msaa_image), "CreateImage (msaa)")

	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g.device, g.msaa_image, &req)
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(g, req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(g.device, &alloc, nil, &g.msaa_memory), "AllocateMemory (msaa)")
	vk.BindImageMemory(g.device, g.msaa_image, g.msaa_memory, 0)

	view := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = g.msaa_image,
		viewType = .D2,
		format = g.format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_check(vk.CreateImageView(g.device, &view, nil, &g.msaa_view), "CreateImageView (msaa)")
}

@(private = "file")
destroy_msaa_target :: proc(g: ^Gpu) {
	if g.msaa_view != 0 do vk.DestroyImageView(g.device, g.msaa_view, nil)
	if g.msaa_image != 0 do vk.DestroyImage(g.device, g.msaa_image, nil)
	if g.msaa_memory != 0 do vk.FreeMemory(g.device, g.msaa_memory, nil)
	g.msaa_view = 0
	g.msaa_image = 0
	g.msaa_memory = 0
}

@(private = "file")
destroy_swapchain_views :: proc(g: ^Gpu) {
	for v in g.views do vk.DestroyImageView(g.device, v, nil)
	for s in g.present_sems do vk.DestroySemaphore(g.device, s, nil)
	delete(g.views)
	delete(g.present_sems)
	delete(g.images)
}

gpu_resize :: proc(g: ^Gpu, width, height: int) {
	vk.DeviceWaitIdle(g.device)
	create_swapchain(g, u32(width), u32(height))
}

@(private = "file")
create_frames :: proc(g: ^Gpu) {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = g.queue_family,
	}
	vk_check(vk.CreateCommandPool(g.device, &pool_info, nil, &g.cmd_pool), "CreateCommandPool")

	for &f in g.frames {
		alloc := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = g.cmd_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		vk_check(vk.AllocateCommandBuffers(g.device, &alloc, &f.cmd), "AllocateCommandBuffers")

		fence_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		vk_check(vk.CreateFence(g.device, &fence_info, nil, &f.fence), "CreateFence")

		sem_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(vk.CreateSemaphore(g.device, &sem_info, nil, &f.acquire), "CreateSemaphore")

		f.vbuf, f.vmem, f.vmapped = create_mapped_buffer(g, VERTEX_BYTES, {.VERTEX_BUFFER})
		f.ibuf, f.imem, f.imapped = create_mapped_buffer(g, INDEX_BYTES, {.INDEX_BUFFER})
	}
}

// Host-visible, persistently mapped: UI geometry is rewritten every frame, so
// staging it through device-local memory would cost more than it saves.
create_mapped_buffer :: proc(
	g: ^Gpu,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (
	buf: vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: [^]byte,
) {
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	vk_check(vk.CreateBuffer(g.device, &info, nil, &buf), "CreateBuffer")

	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g.device, buf, &req)

	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(g, req.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
	}
	vk_check(vk.AllocateMemory(g.device, &alloc, nil, &memory), "AllocateMemory")
	vk.BindBufferMemory(g.device, buf, memory, 0)

	ptr: rawptr
	vk_check(vk.MapMemory(g.device, memory, 0, size, {}, &ptr), "MapMemory")
	return buf, memory, cast([^]byte)ptr
}

find_memory_type :: proc(g: ^Gpu, bits: u32, props: vk.MemoryPropertyFlags) -> u32 {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g.phys, &mem_props)
	for i in 0 ..< mem_props.memoryTypeCount {
		if bits & (1 << i) == 0 do continue
		if props <= mem_props.memoryTypes[i].propertyFlags do return i
	}
	fmt.eprintln("no suitable Vulkan memory type")
	os.exit(1)
}

gpu_destroy :: proc(g: ^Gpu) {
	if g.device == nil do return
	vk.DeviceWaitIdle(g.device)

	for &f in g.frames {
		vk.DestroyBuffer(g.device, f.vbuf, nil)
		vk.FreeMemory(g.device, f.vmem, nil)
		vk.DestroyBuffer(g.device, f.ibuf, nil)
		vk.FreeMemory(g.device, f.imem, nil)
		vk.DestroyFence(g.device, f.fence, nil)
		vk.DestroySemaphore(g.device, f.acquire, nil)
	}
	vk.DestroyCommandPool(g.device, g.cmd_pool, nil)

	destroy_msaa_target(g)
	bindless_destroy(g)
	vk.DestroyPipeline(g.device, g.pipeline, nil)
	vk.DestroyPipelineLayout(g.device, g.pipeline_layout, nil)

	destroy_swapchain_views(g)
	vk.DestroySwapchainKHR(g.device, g.swapchain, nil)
	vk.DestroyDevice(g.device, nil)
	vk.DestroySurfaceKHR(g.instance, g.surface, nil)
	when ODIN_DEBUG {
		if debug_messenger != 0 do vk.DestroyDebugUtilsMessengerEXT(g.instance, debug_messenger, nil)
	}
	vk.DestroyInstance(g.instance, nil)
}
