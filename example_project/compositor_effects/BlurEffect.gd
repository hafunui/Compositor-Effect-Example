@tool
class_name BlurEffect extends CompositorEffect

enum BlurType {BOX, GAUSSIAN}

@export_group("Blur Properties")
@export var blur_type:BlurType = BlurType.BOX
@export_range(1,80, 1) var blur_samples:int = 15
@export_range(1,80, 1, "or_greater") var blur_width:int = 80
@export_range(0,0.5, 0.01) var dither:float = 0
@export_range(1, 4) var mip_level:int = 1

#for sensing when the backbuffers need rebuilding
var size_cache:Vector2i = Vector2i()
var mip_cache:int

var rd:RenderingDevice
var shader:RID
var pipeline:RID
var backbuffers:Array
var backbuffer_format:RDTextureFormat
var texview:RDTextureView
var sampler_state:RDSamplerState
var linear_sampler:RID

#called from main thread when effect is created. In editor, that is once when it is added to effects list
func _init() -> void:
	RenderingServer.call_on_render_thread(initialize_compute_shader)

#this should be called from the rendering thread
func initialize_compute_shader() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd:
		#Make sure this is correctly pointing to the GLSL file
		var glsl_file:RDShaderFile = load("res://example_project/compositor_effects/BlurEffect.glsl")
		shader = rd.shader_create_from_spirv(glsl_file.get_spirv())
		pipeline = rd.compute_pipeline_create(shader)
		sampler_state = RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		linear_sampler = rd.sampler_create(sampler_state)
	
func _notification(what: int) -> void:
	#anything created from rd:RenderingDevice should be freed here when the shader is about to be deleted
	#supposedly the pipeline gets freed with the shader
	if what == NOTIFICATION_PREDELETE and shader.is_valid() and rd:
		rd.free_rid(shader)
		rd.free_rid(linear_sampler)
		for b in backbuffers:
			rd.free_rid(b)
	
func _render_callback(effect_callback_type: int, render_data: RenderData) -> void:
	do_pass(render_data, 1) #horizontal blur
	do_pass(render_data, 2) #vertical blur
	do_pass(render_data, 3) #draw buffers to screen
		
func do_pass(render_data: RenderData, pass_num:int) -> void:
	if not rd: return
	
	#get fresh scene buffers and data for this pass
	var scene_buffers:RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data:RenderSceneDataRD = render_data.get_render_scene_data()
	if not scene_buffers and not scene_data:return
	
	#viewport size
	var size:Vector2i= scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0: return
	
	#shader workgroup sizes. Correlates with local size in shader
	#for pass 1 and 2, match to size of scaled buffer
	var x_groups:int
	var y_groups:int
	if pass_num == 1 or pass_num == 2:
		x_groups = (size.x/mip_level) / 16 + 1
		y_groups = (size.y/mip_level) / 16 + 1
	else:
		x_groups = size.x / 16 + 1
		y_groups = size.y / 16 + 1
	
	#check backbuffers. Create new ones if view size or count changed, of if this is first run
	var view_count:int = scene_buffers.get_view_count()
	if backbuffers.size() < view_count*2 or size_cache != size or mip_cache != mip_level:
		init_backbuffer(view_count*2, size)
	
	#inverse projection matrix from camera. Used to transform depth buffer into something linear
	var inv_proj_mat:Projection = scene_data.get_cam_projection().inverse()
	
	#Push constants - make sure everything is in the same order as shader
	var packed_bytes:PackedByteArray = PackedByteArray()
	var packed_floats:PackedFloat32Array = PackedFloat32Array()
	var packed_ints:PackedInt32Array = PackedInt32Array()
	
	#floats
	#send the size of the texture we're writing to
	if pass_num == 1 or pass_num == 2:
		packed_floats.append(size.x/mip_level) #screen_size.x
		packed_floats.append(size.y/mip_level) #screen_size.y
	else:
		packed_floats.append(size.x) #screen_size.x
		packed_floats.append(size.y) #screen_size.y
	packed_floats.append(dither) #dither amount
	packed_bytes.append_array(packed_floats.to_byte_array())
	
	#ints
	packed_ints.append(1 if blur_type == BlurType.GAUSSIAN else 0)
	packed_ints.append(min(blur_samples, blur_width))
	packed_ints.append(blur_width)
	packed_ints.append(pass_num)
	packed_bytes.append_array(packed_ints.to_byte_array())
	
	#padding. If the console complains about not supplying enough bytes, input requested amount here
	packed_bytes.resize(32)
	
	#do for each view. Normally only 1 view, but VR may use 2
	for view in view_count:
		var screen_tex:RID = scene_buffers.get_color_layer(view)
		var uniform:RDUniform
		var screen_image_uniform_set:RID
		var backbuffer_uniform_set1:RID
		var backbuffer_uniform_set2:RID

		#we'll read from samplers, and write to images
		if pass_num == 1:
			#pass1 read from screen, horizontal blur to scaled buffer 1
			uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			uniform.binding = 0
			uniform.add_id(backbuffers[view]) #0
			backbuffer_uniform_set1 = UniformSetCacheRD.get_cache(shader, 0, [uniform])
			
			uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.binding = 0
			uniform.add_id(linear_sampler)
			uniform.add_id(screen_tex)
			screen_image_uniform_set = UniformSetCacheRD.get_cache(shader, 1, [uniform])
		elif pass_num == 2:
			#pass2 read from scaled buffer 1, vertical blur to scaled buffer 2
			uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			uniform.binding = 0
			uniform.add_id(backbuffers[view_count + view]) #1
			backbuffer_uniform_set2 = UniformSetCacheRD.get_cache(shader, 0, [uniform])
			
			uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.binding = 0
			uniform.add_id(linear_sampler)
			uniform.add_id(backbuffers[view]) #0
			backbuffer_uniform_set1 = UniformSetCacheRD.get_cache(shader, 1, [uniform])
		else: #pass3
			#pass3 read from scaled buffer 2, copy to screen
			uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			uniform.binding = 0
			uniform.add_id(screen_tex)
			backbuffer_uniform_set2 = UniformSetCacheRD.get_cache(shader, 0, [uniform])
			
			uniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.binding = 0
			uniform.add_id(linear_sampler)
			uniform.add_id(backbuffers[view_count + view])
			screen_image_uniform_set = UniformSetCacheRD.get_cache(shader, 1, [uniform])

		#pass1 - screen, buffer1
		#pass2 - buffer1, buffer2
		#pass3 - buffer2, screen1
		var compute_list:int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		if pass_num == 1:
			rd.compute_list_bind_uniform_set(compute_list, backbuffer_uniform_set1, 0)
			rd.compute_list_bind_uniform_set(compute_list, screen_image_uniform_set, 1)
		elif pass_num == 2:
			rd.compute_list_bind_uniform_set(compute_list, backbuffer_uniform_set2, 0)
			rd.compute_list_bind_uniform_set(compute_list, backbuffer_uniform_set1, 1)
		else: #pass3
			rd.compute_list_bind_uniform_set(compute_list, screen_image_uniform_set, 1)
			rd.compute_list_bind_uniform_set(compute_list, backbuffer_uniform_set2, 0)
		rd.compute_list_set_push_constant(compute_list, packed_bytes, packed_bytes.size())
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

func init_backbuffer(count:int, size:Vector2i) -> void:
	#remember to properly free the buffers else the memory leak will blow up your pc
	for b in backbuffers:
		rd.free_rid(b)
	backbuffers.clear()
	
	if not backbuffer_format:
		backbuffer_format = RDTextureFormat.new()
	#theres loads of formats to choose from. This one is RGBA 16bit float with values 0.0 - 1.0
	backbuffer_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM
	backbuffer_format.width = size.x / mip_level
	backbuffer_format.height = size.y / mip_level
	backbuffer_format.usage_bits = \
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + \
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT + \
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	if not texview:
		texview = RDTextureView.new()
		
	for i in count:
		backbuffers.append(rd.texture_create(backbuffer_format, texview))
	
	mip_cache = mip_level
	size_cache.x = size.x
	size_cache.y = size.y
