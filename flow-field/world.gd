extends Node2D

@export var has_ui: bool = true
@export var use_trails := true
@export var trail_steps := 20
@export var flow_field := false
@export var cell_size := 20.0
@export var noise_density := 10.0
@export var shift_speed := 1.0
@export var debug_vector_size := -1.0
@export var feromone_field := true
@export var feromone_cell_size := 5.0
@export var sensor_angle := 0.5 # radians
@export var sensor_distance := 30.0
@export var pheromone_steering_force := 100.0

var noise := FastNoiseLite.new()
var grid: PackedVector2Array
var cols: int
var rows: int
var cell_count: int
var time := 0.0

var feromone_grid: PackedFloat32Array
var feromone_rows: int
var feromone_cols: int
var feromone_cell_count: int

@export var particle_count := 500
@export var max_velocity := 150.0
@export var max_acceleration := 50.0
@export var particle_radius := 3.0
@export var particle_color := Color.WHITE

var positions: PackedVector2Array
var velocities: PackedVector2Array
var accelerations: PackedVector2Array

var particle_multimesh: MultiMeshInstance2D

# ui
var particle_count_slider: HSlider
var noise_density_slider: HSlider
var noise_shift_speed_slider: HSlider

var particle_color_picker: ColorPickerButton

# trails
var history: Array[PackedVector2Array]

func _ready() -> void:
	cols = ceili(get_viewport_rect().size.x/cell_size)
	rows = ceili(get_viewport_rect().size.y/cell_size)
	cell_count = cols*rows
	grid.resize(cell_count)
	grid.fill(Vector2.RIGHT)
	
	feromone_cols = ceili(get_viewport_rect().size.x/feromone_cell_size)
	feromone_rows = ceili(get_viewport_rect().size.y/feromone_cell_size)
	feromone_cell_count = feromone_cols*feromone_rows
	feromone_grid.resize(feromone_cell_count)
	feromone_grid.fill(0.0)
	
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	
	create_particles()
	
	if not has_ui:
		return
	
	Utils.UI.setup(self)
	Utils.UI.dynamic_label(func(): return "FPS: " + str(Engine.get_frames_per_second()))
	particle_count_slider = Utils.UI.labeled_slider("Particle Count on Reset: ", 1000, 50000, 100, 10000)
	noise_density_slider = Utils.UI.labeled_slider("Noise Density: ", 1, 50, 1, 10)
	noise_shift_speed_slider = Utils.UI.labeled_slider("Shift Speed: ", 1, 30, 1, 1)
	
	particle_color_picker = ColorPickerButton.new()
	particle_color_picker.color = particle_color
	particle_color_picker.color_changed.connect(_on_particle_color_changed)
	Utils.UI.content.add_child(particle_color_picker)
	
	Utils.UI.button("Reset", reset_simulation)
	
	Utils.UI.quit_button(self)

func _on_particle_color_changed(color: Color) -> void:
	particle_color = color
	particle_multimesh.material.set_shader_parameter("particle_color", color)

func apply_sliders() -> void:
	noise_density = noise_density_slider.value
	shift_speed = noise_shift_speed_slider.value

func _process(_delta: float) -> void:
	time += _delta

	if has_ui: apply_sliders()
	
	if (flow_field):
		for i in range(len(grid)):
			var x := i%cols
			@warning_ignore("integer_division")
			var y := i/cols
			var n = noise.get_noise_3d(x * noise_density, y * noise_density, time * shift_speed)
			grid[i] = Vector2.from_angle(n*PI).normalized()
	
	if (feromone_field):
		update_feromone_grid()
		follow_feromones()
	
	update_particles(_delta)
	update_particle_rendering()
	
	if (use_trails):
		history.append(positions.duplicate())
		if len(history) >= trail_steps:
			history.remove_at(0)
	
	queue_redraw()

func update_particles(delta: float) -> void:
	if (flow_field):
		for i in range(len(accelerations)):
			var pos := positions[i]
			var x := floori(pos.x/cell_size)
			var y := floori(pos.y/cell_size)
			var index := x + y*cols
			if (index < len(grid) and index >= 0):
				accelerations[i] = grid[index] * max_acceleration * 100.0
	
	for i in range(particle_count):
		velocities[i] += accelerations[i] * delta

		if velocities[i].length() > max_velocity * 100.0:
			velocities[i] = velocities[i].normalized() * max_velocity * 100.0

		positions[i] += velocities[i] * delta
		
		if (positions[i].x > get_viewport_rect().size.x):
			positions[i].x -= get_viewport_rect().size.x
		
		if (positions[i].y > get_viewport_rect().size.y):
			positions[i].y -= get_viewport_rect().size.y
		
		if (positions[i].x < 0):
			positions[i].x += get_viewport_rect().size.x
		
		if (positions[i].y < 0):
			positions[i].y += get_viewport_rect().size.y

	update_particle_rendering()

func update_feromone_grid() -> void:
	for i in range(len(positions)):
		var pos = positions[i]
		var x := floori(pos.x/feromone_cell_size)
		var y := floori(pos.y/feromone_cell_size)
		if inbound(x, y, feromone_cols, feromone_rows):
			var index = x + y * feromone_cols
			feromone_grid[index] += 1.0
	
	var new_grid: PackedFloat32Array
	new_grid.resize(feromone_cell_count)
	new_grid.fill(0.0)
	for row in range(feromone_rows):
		for col in range(feromone_cols):
			var sum := 0.0
			for x in [-1, 0, 1]:
				for y in [-1, 0, 1]:
					if not inbound(col+x, row+y, feromone_cols, feromone_rows):
						sum += 0.0
					else:
						sum += feromone_grid[(col + x) + (row + y) * feromone_cols]
			new_grid[col + row * feromone_cols] = sum/9.0
	for i in range(len(new_grid)):
		new_grid[i] *= 0.99
	feromone_grid = new_grid

func inbound(x: int, y: int, width: int, height: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func follow_feromones() -> void:
	for i in range(particle_count):
		var forward := velocities[i].normalized()
		var left := forward.rotated(-sensor_angle)
		var right := forward.rotated(sensor_angle)

		var directions := [left, forward, right]
		var best_strength := -INF
		var best_direction := forward

		for direction in directions:
			var sensor_pos = positions[i] + direction * sensor_distance

			# Wrap sensor position around the screen.
			var screen_size := get_viewport_rect().size
			sensor_pos.x = wrapf(sensor_pos.x, 0.0, screen_size.x)
			sensor_pos.y = wrapf(sensor_pos.y, 0.0, screen_size.y)

			# Convert sensor position to pheromone grid coordinates.
			var x := floori(sensor_pos.x / feromone_cell_size)
			var y := floori(sensor_pos.y / feromone_cell_size)

			var index := x + y * feromone_cols
			var strength := feromone_grid[index]

			if strength > best_strength:
				best_strength = strength
				best_direction = direction

		accelerations[i] = best_direction * pheromone_steering_force * 100.0


func create_circle_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
	shader_type canvas_item;

	uniform vec4 particle_color : source_color = vec4(1.0);

	void fragment() {
	    vec2 centered_uv = UV - vec2(0.5);
	    float distance_from_center = length(centered_uv);

	    float aa = fwidth(distance_from_center);
	    float alpha = 1.0 - smoothstep(0.5 - aa, 0.5 + aa, distance_from_center);

	    COLOR = vec4(particle_color.rgb, alpha * particle_color.a);
	}
	"""
	return shader

func create_particles() -> void:
	if particle_multimesh:
		particle_multimesh.queue_free()
	
	positions.resize(particle_count)
	velocities.resize(particle_count)
	accelerations.resize(particle_count)

	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * particle_radius * 2.0

	var shader_material := ShaderMaterial.new()
	shader_material.shader = create_circle_shader()
	shader_material.set_shader_parameter("particle_color", particle_color)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.mesh = mesh
	multimesh.instance_count = particle_count

	particle_multimesh = MultiMeshInstance2D.new()
	particle_multimesh.multimesh = multimesh
	particle_multimesh.material = shader_material
	add_child(particle_multimesh)

	randomize_particles()

func randomize_particles() -> void:
	var viewport_size := get_viewport_rect().size

	for i in range(particle_count):
		positions[i] = Vector2(
			Utils.Rnd.range_f(0.0, viewport_size.x),
			Utils.Rnd.range_f(0.0, viewport_size.y)
		)

		velocities[i] = Vector2.from_angle(
			Utils.Rnd.range_f(0.0, TAU)
		) * Utils.Rnd.range_f(0.0, max_velocity)

		accelerations[i] = Vector2.from_angle(
			Utils.Rnd.range_f(0.0, TAU)
		) * Utils.Rnd.range_f(0.0, max_acceleration)

	update_particle_rendering()

func update_particle_rendering() -> void:
	for i in range(particle_count):
		var trans := Transform2D(0.0, positions[i])
		particle_multimesh.multimesh.set_instance_transform_2d(i, trans)

func draw_vectors() -> void:
	for i in range(len(grid)):
		var x := i%cols
		@warning_ignore("integer_division")
		var y := i/cols
		var pos := Vector2(x+0.5, y+0.5) * cell_size
		draw_line(pos, pos + grid[i]*debug_vector_size, Color.WHITE, 1, true)

func _draw() -> void:
	if not debug_vector_size == -1: draw_vectors()
	
	if use_trails:
		for p in range(particle_count):
			for i in range(len(history)):
				if i == 0:
					continue
				
				var a = history[i][p]
				var b = history[i-1][p]

				if a.distance_to(b) < 100:
					draw_line(a, b, particle_color, 1, true)

func reset_simulation() -> void:
	apply_sliders()
	
	@warning_ignore("narrowing_conversion")
	particle_count = particle_count_slider.value
	
	create_particles()
	randomize_particles()
	
	history.clear()
	history.append(positions)
