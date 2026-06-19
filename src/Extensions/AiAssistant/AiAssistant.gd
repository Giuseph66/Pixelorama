extends Node

const GeminiService := preload("res://src/Extensions/AiAssistant/GeminiService.gd")
const MAX_CHANGED_PIXELS := 65536

var extension_api: Node
var _service: Node
var _panel: Control
var _api_key_edit: LineEdit
var _model_edit: LineEdit
var _prompt_edit: TextEdit
var _send_button: Button
var _apply_button: Button
var _status_label: Label
var _result_label: RichTextLabel
var _confirm_dialog: ConfirmationDialog
var _pending_response: Dictionary
var _request_project
var _request_frame := -1
var _request_layer := -1


func _enter_tree() -> void:
	extension_api = get_node_or_null("/root/ExtensionsApi")
	_service = GeminiService.new()
	_service.request_succeeded.connect(_on_request_succeeded)
	_service.request_failed.connect(_on_request_failed)
	add_child(_service)
	_panel = _build_panel()
	if extension_api:
		extension_api.panel.add_node_as_tab(_panel)


func _exit_tree() -> void:
	if extension_api and is_instance_valid(_panel):
		extension_api.panel.remove_node_from_tab(_panel)


func _build_panel() -> Control:
	var panel := Control.new()
	panel.name = "AI Assistant"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	var title := Label.new()
	title.text = "Gemini Pixel Assistant"
	title.add_theme_font_size_override("font_size", 18)
	content.add_child(title)

	_api_key_edit = LineEdit.new()
	_api_key_edit.secret = true
	_api_key_edit.placeholder_text = "Gemini API key (or GEMINI_API_KEY)"
	_api_key_edit.tooltip_text = "Kept only in memory. Web builds should use a backend proxy."
	content.add_child(_api_key_edit)

	_model_edit = LineEdit.new()
	_model_edit.text = "gemini-2.5-flash"
	_model_edit.placeholder_text = "Model ID"
	content.add_child(_model_edit)

	_prompt_edit = TextEdit.new()
	_prompt_edit.placeholder_text = (
		"Example: improve the sword outline without changing the character."
	)
	_prompt_edit.custom_minimum_size.y = 100
	_prompt_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_prompt_edit)

	var actions := HBoxContainer.new()
	content.add_child(actions)
	_send_button = Button.new()
	_send_button.text = "Analyze current cel"
	_send_button.pressed.connect(_on_send_pressed)
	actions.add_child(_send_button)
	_apply_button = Button.new()
	_apply_button.text = "Apply changes"
	_apply_button.disabled = true
	_apply_button.pressed.connect(_on_apply_pressed)
	actions.add_child(_apply_button)

	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status_label)

	_result_label = RichTextLabel.new()
	_result_label.bbcode_enabled = true
	_result_label.selection_enabled = true
	_result_label.fit_content = true
	_result_label.custom_minimum_size.y = 80
	content.add_child(_result_label)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Apply AI changes?"
	_confirm_dialog.confirmed.connect(_apply_pending_response)
	panel.add_child(_confirm_dialog)
	return panel


func _on_send_pressed() -> void:
	if not extension_api:
		_show_error("Extensions API is unavailable.")
		return
	var project = extension_api.project.current_project
	var cel = extension_api.project.get_current_cel()
	if cel == null or cel.get_class_name() != "PixelCel":
		_show_error("Select a pixel cel first.")
		return
	var api_key := _api_key_edit.text.strip_edges()
	if api_key.is_empty():
		api_key = OS.get_environment("GEMINI_API_KEY")
	_service.configure(api_key, _model_edit.text)
	_request_project = project
	_request_frame = project.current_frame
	_request_layer = project.current_layer
	_pending_response.clear()
	_apply_button.disabled = true
	_set_busy(true, "Analyzing current cel...")
	var image: Image = cel.get_image().duplicate()
	var context := {
		"canvas_width": image.get_width(),
		"canvas_height": image.get_height(),
		"frame": _request_frame,
		"layer": _request_layer,
		"project_name": project.name
	}
	_service.analyze_cel(_prompt_edit.text, image, context)


func _on_request_succeeded(response: Dictionary) -> void:
	_set_busy(false, "Proposal ready")
	var operations = response.get("operations", [])
	if typeof(operations) != TYPE_ARRAY:
		_show_error("Gemini response has invalid operations.")
		return
	_pending_response = response
	_result_label.text = "[b]Assistant[/b]\n%s\n\n[b]Operations:[/b] %d" % [
		_escape_bbcode(str(response.get("message", ""))), operations.size()
	]
	_apply_button.disabled = operations.is_empty()


func _on_request_failed(message: String) -> void:
	_set_busy(false, "Request failed")
	_show_error(message)


func _on_apply_pressed() -> void:
	if _pending_response.is_empty():
		return
	var operations: Array = _pending_response.get("operations", [])
	_confirm_dialog.dialog_text = "Apply %d AI operation(s) to frame %d, layer %d?" % [
		operations.size(), _request_frame + 1, _request_layer + 1
	]
	_confirm_dialog.popup_centered()


func _apply_pending_response() -> void:
	if _request_project != extension_api.project.current_project:
		_show_error("The active project changed. Request a new proposal.")
		return
	var project = _request_project
	if _request_frame < 0 or _request_frame >= project.frames.size():
		_show_error("The target frame no longer exists.")
		return
	if _request_layer < 0 or _request_layer >= project.layers.size():
		_show_error("The target layer no longer exists.")
		return
	var cel = project.frames[_request_frame].cels[_request_layer]
	if cel == null or cel.get_class_name() != "PixelCel":
		_show_error("The target is no longer a pixel cel.")
		return
	var image = cel.get_image()
	var validated := _validate_operations(
		_pending_response.get("operations", []), image.get_width(), image.get_height()
	)
	if not validated.ok:
		_show_error(validated.error)
		return

	var undo_data := {}
	image.add_data_to_dictionary(undo_data)
	for operation in validated.operations:
		_execute_operation(image, operation)
	image.convert_rgb_to_indexed()
	var redo_data := {}
	image.add_data_to_dictionary(redo_data)
	project.undo_redo.create_action("AI pixel edit")
	project.deserialize_cel_undo_data(redo_data, undo_data)
	project.undo_redo.add_do_method(cel.update_texture)
	project.undo_redo.add_undo_method(cel.update_texture)
	project.undo_redo.add_do_method(
		Global.undo_or_redo.bind(false, _request_frame, _request_layer, project)
	)
	project.undo_redo.add_undo_method(
		Global.undo_or_redo.bind(true, _request_frame, _request_layer, project)
	)
	project.undo_redo.commit_action()
	_pending_response.clear()
	_apply_button.disabled = true
	_status_label.text = "Changes applied"


func _validate_operations(operations, width: int, height: int) -> Dictionary:
	if typeof(operations) != TYPE_ARRAY or operations.size() > 64:
		return {"ok": false, "error": "Invalid operation list."}
	var validated: Array[Dictionary] = []
	var changed_pixels := 0
	for operation in operations:
		if typeof(operation) != TYPE_DICTIONARY:
			return {"ok": false, "error": "Invalid operation."}
		match operation.get("type", ""):
			"set_pixels":
				var pixels = operation.get("pixels", [])
				if typeof(pixels) != TYPE_ARRAY:
					return {"ok": false, "error": "Invalid pixel list."}
				var valid_pixels: Array[Dictionary] = []
				for pixel in pixels:
					if typeof(pixel) != TYPE_DICTIONARY:
						return {"ok": false, "error": "Invalid pixel entry."}
					var x := int(pixel.get("x", -1))
					var y := int(pixel.get("y", -1))
					var color := str(pixel.get("color", ""))
					if (
						x < 0
						or x >= width
						or y < 0
						or y >= height
						or not Color.html_is_valid(color)
					):
						return {
							"ok": false,
							"error": "Pixel is outside the canvas or has an invalid color."
						}
					valid_pixels.append({"x": x, "y": y, "color": color})
				changed_pixels += valid_pixels.size()
				validated.append({"type": "set_pixels", "pixels": valid_pixels})
			"fill_rect":
				var x := int(operation.get("x", -1))
				var y := int(operation.get("y", -1))
				var rect_width := int(operation.get("width", 0))
				var rect_height := int(operation.get("height", 0))
				var color := str(operation.get("color", ""))
				if (
					x < 0
					or y < 0
					or rect_width <= 0
					or rect_height <= 0
					or x + rect_width > width
					or y + rect_height > height
					or not Color.html_is_valid(color)
				):
					return {
						"ok": false,
						"error": "Rectangle is outside the canvas or has an invalid color."
					}
				changed_pixels += rect_width * rect_height
				validated.append(
					{
						"type": "fill_rect",
						"rect": Rect2i(x, y, rect_width, rect_height),
						"color": color
					}
				)
			_:
				return {"ok": false, "error": "Unsupported AI operation."}
		if changed_pixels > MAX_CHANGED_PIXELS:
			return {"ok": false, "error": "AI proposal changes too many pixels."}
	return {"ok": true, "operations": validated}


func _execute_operation(image: Image, operation: Dictionary) -> void:
	match operation.type:
		"set_pixels":
			for pixel in operation.pixels:
				image.set_pixel(pixel.x, pixel.y, Color.from_string(pixel.color, Color.TRANSPARENT))
		"fill_rect":
			image.fill_rect(operation.rect, Color.from_string(operation.color, Color.TRANSPARENT))


func _set_busy(busy: bool, status: String) -> void:
	_send_button.disabled = busy
	_status_label.text = status


func _show_error(message: String) -> void:
	_status_label.text = message
	_result_label.text = "[color=red]%s[/color]" % _escape_bbcode(message)


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")
