extends Node
## Color Blindness Preview extension for Pixelorama.
##
## Adds a small icon button next to the mirror / symmetry toggles in the Global
## Tool Options. Clicking it opens a modal window that shows the current frame
## simulated under common color vision deficiencies (protanopia, deuteranopia,
## tritanopia, achromatopsia), live as you draw. Helps verify sprites and UI
## palettes stay readable for color blind players.
##
## This node is purely a controller and only *reads* the project; it never
## writes pixels. It injects the button into the existing GlobalToolOptions grid
## at runtime, so no core scene is modified.

# Names match the OptionButton item order below.
enum { MODE_NORMAL, MODE_PROTANOPIA, MODE_DEUTERANOPIA, MODE_TRITANOPIA, MODE_ACHROMATOPSIA }

const ICON_PATH := "res://assets/graphics/layers/layer_visible.png"
# Sibling button used to locate the mirror toolbar and to insert right after it.
const ANCHOR_BUTTON := "DiagonalXMinusY"

var extension_api: Node  # /root/ExtensionsApi

var _button: Button
var _window: Window
var _preview: TextureRect
var _mode_option: OptionButton
var _severity_slider: HSlider
var _material: ShaderMaterial
var _signals_connected := false

# CanvasItem shader. Simulates color vision deficiency by mixing each pixel
# towards a deficiency matrix, scaled by `severity` (0 = normal, 1 = full).
# Matrices are the widely used sRGB simulation approximations.
const SHADER_CODE := """
shader_type canvas_item;
render_mode unshaded;

uniform int mode = 0;
uniform float severity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	vec3 c = src.rgb;
	vec3 sim = c;
	if (mode == 1) { // Protanopia
		sim = vec3(
			dot(c, vec3(0.567, 0.433, 0.000)),
			dot(c, vec3(0.558, 0.442, 0.000)),
			dot(c, vec3(0.000, 0.242, 0.758)));
	} else if (mode == 2) { // Deuteranopia
		sim = vec3(
			dot(c, vec3(0.625, 0.375, 0.000)),
			dot(c, vec3(0.700, 0.300, 0.000)),
			dot(c, vec3(0.000, 0.300, 0.700)));
	} else if (mode == 3) { // Tritanopia
		sim = vec3(
			dot(c, vec3(0.950, 0.050, 0.000)),
			dot(c, vec3(0.000, 0.433, 0.567)),
			dot(c, vec3(0.000, 0.475, 0.525)));
	} else if (mode == 4) { // Achromatopsia (full color blindness)
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		sim = vec3(l, l, l);
	}
	COLOR = vec4(mix(c, sim, severity), src.a);
}
"""


func _enter_tree() -> void:
	extension_api = get_node_or_null("/root/ExtensionsApi")
	_build_window()
	# Defer the button injection: GlobalToolOptions may not be in the tree yet
	# on the first frame an internal extension loads.
	call_deferred("_inject_button")


func _exit_tree() -> void:
	_disconnect_signals()
	if is_instance_valid(_button):
		_button.queue_free()
	if is_instance_valid(_window):
		_window.queue_free()


func _inject_button() -> void:
	var grid := _find_mirror_grid()
	if grid == null:
		push_warning("Color Blindness Preview: mirror toolbar not found, button not added.")
		return
	var anchor := grid.find_child(ANCHOR_BUTTON, false, false)

	_button = Button.new()
	_button.custom_minimum_size = Vector2(32, 32)
	_button.tooltip_text = "Color blindness preview"
	_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_button.pressed.connect(_on_button_pressed)

	var icon := TextureRect.new()
	icon.texture = load(ICON_PATH)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 6
	icon.offset_top = 6
	icon.offset_right = -6
	icon.offset_bottom = -6
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_button.add_child(icon)

	grid.add_child(_button)
	if anchor:
		grid.move_child(_button, anchor.get_index() + 1)


## Walks up from a known mirror button to its parent GridContainer.
func _find_mirror_grid() -> Node:
	var global = get_node_or_null("/root/Global")
	if not global or not global.control:
		return null
	var anchor = global.control.find_child(ANCHOR_BUTTON, true, false)
	return anchor.get_parent() if anchor else null


func _build_window() -> void:
	_window = Window.new()
	_window.title = "Color Blindness Preview"
	_window.size = Vector2i(420, 380)
	_window.min_size = Vector2i(260, 220)
	_window.visible = false
	_window.transient = true
	_window.exclusive = false
	_window.unresizable = false
	_window.close_requested.connect(_on_window_close)
	add_child(_window)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	_window.add_child(vbox)

	var toolbar := HBoxContainer.new()
	vbox.add_child(toolbar)

	var mode_label := Label.new()
	mode_label.text = "Type:"
	toolbar.add_child(mode_label)

	_mode_option = OptionButton.new()
	# Order must match the MODE_* enum.
	_mode_option.add_item("Normal vision")
	_mode_option.add_item("Protanopia (no red)")
	_mode_option.add_item("Deuteranopia (no green)")
	_mode_option.add_item("Tritanopia (no blue)")
	_mode_option.add_item("Achromatopsia (no color)")
	_mode_option.item_selected.connect(_on_mode_selected)
	toolbar.add_child(_mode_option)

	var severity_label := Label.new()
	severity_label.text = "Severity:"
	toolbar.add_child(severity_label)

	_severity_slider = HSlider.new()
	_severity_slider.min_value = 0.0
	_severity_slider.max_value = 1.0
	_severity_slider.step = 0.05
	_severity_slider.value = 1.0
	_severity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_severity_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_severity_slider.value_changed.connect(_on_severity_changed)
	toolbar.add_child(_severity_slider)

	var add_frame_btn := Button.new()
	add_frame_btn.text = "+"
	add_frame_btn.tooltip_text = "Add the simulated image as a new frame"
	add_frame_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_frame_btn.pressed.connect(_on_add_frame_pressed)
	toolbar.add_child(add_frame_btn)

	_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER_CODE
	_material.shader = shader
	_material.set_shader_parameter("mode", MODE_NORMAL)
	_material.set_shader_parameter("severity", 1.0)

	_preview = TextureRect.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Nearest filtering keeps the pixel art crisp when scaled up.
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.material = _material
	vbox.add_child(_preview)


func _on_button_pressed() -> void:
	if not is_instance_valid(_window):
		return
	_connect_signals()
	_refresh_preview()
	_window.popup_centered()


func _on_window_close() -> void:
	# Stop reacting to canvas changes while the modal is hidden.
	_disconnect_signals()
	_window.hide()


## Bakes the current simulation (CPU, same matrices as the shader) and inserts
## the result as a new frame on the current layer of the active project.
func _on_add_frame_pressed() -> void:
	var image := _current_frame_image()
	if image == null or image.is_empty():
		return
	_simulate_image(image, _mode_option.selected, float(_severity_slider.value))
	var global = get_node_or_null("/root/Global")
	var layer_index: int = global.current_project.current_layer if global else 0
	var open_save = extension_api.import.open_save_autoload()
	open_save.open_image_as_new_frame(image, layer_index)


## Applies the color vision deficiency matrix to [param image] in place.
## Mirrors SHADER_CODE so the baked frame matches the live preview.
func _simulate_image(image: Image, mode: int, severity: float) -> void:
	if mode == MODE_NORMAL or severity <= 0.0:
		return
	var width := image.get_width()
	var height := image.get_height()
	for y in height:
		for x in width:
			var c := image.get_pixel(x, y)
			var sim := c
			match mode:
				MODE_PROTANOPIA:
					sim = Color(
						c.r * 0.567 + c.g * 0.433,
						c.r * 0.558 + c.g * 0.442,
						c.g * 0.242 + c.b * 0.758
					)
				MODE_DEUTERANOPIA:
					sim = Color(
						c.r * 0.625 + c.g * 0.375,
						c.r * 0.700 + c.g * 0.300,
						c.g * 0.300 + c.b * 0.700
					)
				MODE_TRITANOPIA:
					sim = Color(
						c.r * 0.950 + c.g * 0.050,
						c.g * 0.433 + c.b * 0.567,
						c.g * 0.475 + c.b * 0.525
					)
				MODE_ACHROMATOPSIA:
					var l := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
					sim = Color(l, l, l)
			# Mix rgb towards the simulation; keep the original alpha untouched.
			var out := c.lerp(sim, severity).clamp()
			out.a = c.a
			image.set_pixel(x, y, out)


func _on_mode_selected(index: int) -> void:
	_material.set_shader_parameter("mode", index)


func _on_severity_changed(value: float) -> void:
	_material.set_shader_parameter("severity", value)


func _connect_signals() -> void:
	if _signals_connected or not extension_api:
		return
	var s = extension_api.signals
	s.signal_current_cel_texture_changed(_refresh_preview)
	s.signal_cel_switched(_refresh_preview)
	s.signal_project_switched(_refresh_preview)
	s.signal_project_data_changed(_on_project_data_changed)
	_signals_connected = true


func _disconnect_signals() -> void:
	if not _signals_connected or not extension_api:
		return
	var s = extension_api.signals
	s.signal_current_cel_texture_changed(_refresh_preview, true)
	s.signal_cel_switched(_refresh_preview, true)
	s.signal_project_switched(_refresh_preview, true)
	s.signal_project_data_changed(_on_project_data_changed, true)
	_signals_connected = false


# signal_project_data_changed passes the affected project as an argument.
func _on_project_data_changed(_project = null) -> void:
	_refresh_preview()


## Composites the current frame's visible layers and feeds the result to the
## preview TextureRect. The shader handles the color vision deficiency mapping.
func _refresh_preview() -> void:
	if not is_instance_valid(_preview):
		return
	var image := _current_frame_image()
	if image == null or image.is_empty():
		_preview.texture = null
		return
	_preview.texture = ImageTexture.create_from_image(image)


func _current_frame_image() -> Image:
	if not extension_api:
		return null
	var global = get_node_or_null("/root/Global")
	if not global or not global.current_project:
		return null
	var project = global.current_project
	if project.frames.is_empty():
		return null
	var frame = project.frames[project.current_frame]
	var image := Image.create(project.size.x, project.size.y, false, Image.FORMAT_RGBA8)
	var drawing_algos = extension_api.general.get_drawing_algos()
	drawing_algos.blend_layers(image, frame)
	return image
