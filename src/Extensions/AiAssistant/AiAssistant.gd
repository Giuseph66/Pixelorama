extends Node

const GeminiService := preload("res://src/Extensions/AiAssistant/GeminiService.gd")
const MAX_CHANGED_PIXELS := 65536
const WINDOW_MENU := 6
const PANEL_SIZE := Vector2(420, 500)

var extension_api: Node
var _service: Node
var _panel: PanelContainer
var _body: Control
var _title_label: Label
var _accent_indicator: ColorRect
var _model_label: Label
var _minimize_button: Button
var _prompt_edit: TextEdit
var _send_button: Button
var _apply_button: Button
var _status_label: Label
var _result_label: RichTextLabel
var _confirm_dialog: ConfirmationDialog
var _pending_response: Dictionary
var _pending_generated_frames: Array[Image] = []
var _request_project
var _request_frame := -1
var _request_layer := -1
var _request_source_image: Image
var _request_image_hash := 0
var _menu_item_id := -1
var _dragging := false
var _drag_offset := Vector2.ZERO
var _expanded_size := PANEL_SIZE


func _enter_tree() -> void:
	extension_api = get_node_or_null("/root/ExtensionsApi")
	_service = GeminiService.new()
	_service.request_succeeded.connect(_on_request_succeeded)
	_service.image_request_succeeded.connect(_on_image_request_succeeded)
	_service.request_failed.connect(_on_request_failed)
	add_child(_service)
	_panel = _build_panel()
	Global.control.add_child(_panel)
	Themes.theme_switched.connect(_apply_panel_style)
	get_viewport().size_changed.connect(_clamp_panel_position)
	_apply_panel_style()
	_place_initially.call_deferred()
	if extension_api:
		_menu_item_id = extension_api.menu.add_menu_item(
			WINDOW_MENU, "Assistente de IA", self
		)


func _exit_tree() -> void:
	if extension_api and _menu_item_id >= 0:
		extension_api.menu.remove_menu_item(WINDOW_MENU, _menu_item_id)
	if Themes.theme_switched.is_connected(_apply_panel_style):
		Themes.theme_switched.disconnect(_apply_panel_style)
	if get_viewport().size_changed.is_connected(_clamp_panel_position):
		get_viewport().size_changed.disconnect(_clamp_panel_position)
	if is_instance_valid(_panel):
		_panel.queue_free()


func menu_item_clicked() -> void:
	_model_label.text = Global.gemini_model
	_panel.show()
	_panel.get_parent().move_child(_panel, _panel.get_parent().get_child_count() - 1)
	_clamp_panel_position()


func _build_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "Assistente de IA"
	panel.position = Vector2(24, 72)
	panel.size = PANEL_SIZE
	panel.custom_minimum_size.x = 340
	panel.z_index = 100
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 0)
	panel.add_child(shell)

	var header := MarginContainer.new()
	header.custom_minimum_size.y = 42
	header.mouse_default_cursor_shape = Control.CURSOR_DRAG
	header.gui_input.connect(_on_header_gui_input)
	header.add_theme_constant_override("margin_left", 12)
	header.add_theme_constant_override("margin_right", 6)
	shell.add_child(header)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	header.add_child(header_row)

	_accent_indicator = ColorRect.new()
	_accent_indicator.custom_minimum_size = Vector2(4, 18)
	_accent_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(_accent_indicator)
	_accent_indicator.color = Global.theme_accent_color

	_title_label = Label.new()
	_title_label.text = "ASSISTENTE DE PIXEL IA"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(_title_label)

	_minimize_button = Button.new()
	_minimize_button.text = "_"
	_minimize_button.tooltip_text = "Minimizar"
	_minimize_button.custom_minimum_size = Vector2(32, 28)
	_minimize_button.pressed.connect(_toggle_minimized)
	header_row.add_child(_minimize_button)

	var close_button := Button.new()
	close_button.text = "x"
	close_button.tooltip_text = "Fechar; reabra em Janela > Assistente de IA"
	close_button.custom_minimum_size = Vector2(32, 28)
	close_button.pressed.connect(panel.hide)
	header_row.add_child(close_button)

	_body = MarginContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("margin_left", 12)
	_body.add_theme_constant_override("margin_top", 8)
	_body.add_theme_constant_override("margin_right", 12)
	_body.add_theme_constant_override("margin_bottom", 12)
	shell.add_child(_body)

	var content := VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	_body.add_child(content)

	var context_row := HBoxContainer.new()
	content.add_child(context_row)
	var context_label := Label.new()
	context_label.text = "CEL ATUAL"
	context_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	context_label.modulate.a = 0.7
	context_row.add_child(context_label)
	_model_label = Label.new()
	_model_label.text = Global.gemini_model
	_model_label.modulate.a = 0.55
	context_row.add_child(_model_label)

	var prompt_label := Label.new()
	prompt_label.text = "O que deve ser alterado?"
	prompt_label.add_theme_font_size_override("font_size", 15)
	content.add_child(prompt_label)

	_prompt_edit = TextEdit.new()
	_prompt_edit.placeholder_text = "Descreva a edição ou animação desejada..."
	_prompt_edit.custom_minimum_size.y = 150
	_prompt_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_prompt_edit)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	content.add_child(actions)
	_send_button = Button.new()
	_send_button.text = "Gerar com IA"
	_send_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_send_button.pressed.connect(_on_send_pressed)
	actions.add_child(_send_button)
	_apply_button = Button.new()
	_apply_button.text = "Aplicar alterações"
	_apply_button.disabled = true
	_apply_button.pressed.connect(_on_apply_pressed)
	actions.add_child(_apply_button)

	_status_label = Label.new()
	_status_label.text = "Pronto - configuração: Preferências > IA"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.modulate.a = 0.75
	content.add_child(_status_label)

	_result_label = RichTextLabel.new()
	_result_label.bbcode_enabled = true
	_result_label.selection_enabled = true
	_result_label.scroll_active = true
	_result_label.custom_minimum_size.y = 96
	_result_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_result_label.text = "Os detalhes da proposta aparecerão aqui."
	content.add_child(_result_label)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Aplicar alterações da IA?"
	_confirm_dialog.confirmed.connect(_apply_pending_response)
	panel.add_child(_confirm_dialog)
	return panel


func _apply_panel_style() -> void:
	if not is_instance_valid(_panel):
		return
	var style := StyleBoxFlat.new()
	style.bg_color = Global.theme_base_color
	style.border_color = Color(Global.theme_accent_color, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", style)
	_title_label.add_theme_color_override("font_color", Global.theme_accent_color)
	_accent_indicator.color = Global.theme_accent_color


func _place_initially() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	_panel.size = Vector2(
		minf(PANEL_SIZE.x, viewport_size.x - 32),
		minf(PANEL_SIZE.y, viewport_size.y - 96)
	)
	_expanded_size = _panel.size
	_panel.position = Vector2(maxf(16, viewport_size.x - _panel.size.x - 24), 64)
	_clamp_panel_position()


func _on_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_offset = event.global_position - _panel.position


func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		_panel.position = event.position - _drag_offset
		_clamp_panel_position()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed


func _toggle_minimized() -> void:
	if _body.visible:
		_expanded_size = _panel.size
		_body.hide()
		_minimize_button.text = "+"
		_minimize_button.tooltip_text = "Restaurar"
		_set_minimized_size.call_deferred()
	else:
		_body.show()
		_minimize_button.text = "_"
		_minimize_button.tooltip_text = "Minimizar"
		_panel.size = _expanded_size
		_clamp_panel_position.call_deferred()


func _set_minimized_size() -> void:
	_panel.size = Vector2(_expanded_size.x, _panel.get_combined_minimum_size().y)
	_clamp_panel_position()


func _clamp_panel_position() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var max_position := (viewport_size - _panel.size).max(Vector2.ZERO)
	_panel.position = _panel.position.clamp(Vector2.ZERO, max_position)


func _on_send_pressed() -> void:
	if not extension_api:
		_show_error("A API de extensões não está disponível.")
		return
	var project = extension_api.project.current_project
	var cel = extension_api.project.get_current_cel()
	if cel == null or cel.get_class_name() != "PixelCel":
		_show_error("Selecione primeiro uma cel de pixels.")
		return
	var api_key := OS.get_environment("GEMINI_API_KEY")
	if api_key.is_empty():
		api_key = Global.gemini_api_key
	_service.configure(api_key, Global.gemini_model, Global.gemini_image_model)
	_request_project = project
	_request_frame = project.current_frame
	_request_layer = project.current_layer
	_pending_response.clear()
	_pending_generated_frames.clear()
	_apply_button.disabled = true
	var image: Image = cel.get_image().duplicate()
	_request_source_image = image.duplicate()
	_request_image_hash = hash(image.get_data())
	var context := {
		"canvas_width": image.get_width(),
		"canvas_height": image.get_height(),
		"frame": _request_frame,
		"layer": _request_layer,
		"project_name": project.name
	}
	if _is_animation_request(_prompt_edit.text):
		var frame_count := _get_requested_frame_count(_prompt_edit.text)
		_model_label.text = Global.gemini_image_model
		_set_busy(true, "Gerando spritesheet com Nano Banana...")
		_service.generate_animation_sheet(_prompt_edit.text, image, context, frame_count)
	else:
		_model_label.text = Global.gemini_model
		_set_busy(true, "Analisando a cel atual...")
		_service.analyze_cel(_prompt_edit.text, image, context)


func _is_animation_request(prompt: String) -> bool:
	var normalized := prompt.to_lower()
	var animation_terms := [
		"anima", "andar", "andando", "caminh", "corr", "atac", "idle", "walk", "run",
		"attack", "frames", "quadros", "sprites"
	]
	for term in animation_terms:
		if normalized.contains(term):
			return true
	return false


func _get_requested_frame_count(prompt: String) -> int:
	var expression := RegEx.new()
	expression.compile("([2-8])\\s*(frames?|quadros?|sprites?)")
	var result := expression.search(prompt.to_lower())
	if result:
		return result.get_string(1).to_int()
	return 4


func _on_request_succeeded(response: Dictionary) -> void:
	_set_busy(false, "Proposta pronta")
	var operations = response.get("operations", [])
	if typeof(operations) != TYPE_ARRAY:
		_show_error("A resposta do Gemini contém operações inválidas.")
		return
	var animation_frames = response.get("animation_frames", [])
	if typeof(animation_frames) != TYPE_ARRAY:
		_show_error("A resposta do Gemini contém quadros de animação inválidos.")
		return
	_pending_response = response
	_result_label.text = (
		"[b]Assistente[/b]\n%s\n\n[b]Operações na cel atual:[/b] %d\n[b]Novos quadros:[/b] %d"
		% [
			_escape_bbcode(str(response.get("message", ""))),
			operations.size(),
			animation_frames.size()
		]
	)
	_apply_button.disabled = operations.is_empty() and animation_frames.is_empty()


func _on_image_request_succeeded(
	image_data: PackedByteArray, mime_type: String, description: String, frame_count: int
) -> void:
	var sheet := Image.new()
	var error := ERR_INVALID_DATA
	match mime_type:
		"image/png":
			error = sheet.load_png_from_buffer(image_data)
		"image/jpeg":
			error = sheet.load_jpg_from_buffer(image_data)
		"image/webp":
			error = sheet.load_webp_from_buffer(image_data)
	if error != OK or sheet.is_empty():
		_on_request_failed("O Nano Banana retornou uma imagem que não pôde ser decodificada.")
		return
	if sheet.get_width() < frame_count or sheet.get_height() < 1:
		_on_request_failed("O spritesheet retornado possui dimensões inválidas.")
		return
	_pending_generated_frames = _slice_animation_sheet(sheet, frame_count)
	if _pending_generated_frames.size() != frame_count:
		_on_request_failed("Não foi possível separar todos os quadros do spritesheet.")
		return
	_pending_response.clear()
	var response_message := description
	if response_message.is_empty():
		response_message = "Spritesheet gerado pelo Nano Banana e separado em quadros."
	_result_label.text = (
		"[b]Nano Banana[/b]\n%s\n\n[b]Novos quadros:[/b] %d\n[b]Spritesheet:[/b] %dx%d"
		% [
			_escape_bbcode(response_message),
			frame_count,
			sheet.get_width(),
			sheet.get_height()
		]
	)
	_set_busy(false, "Spritesheet pronto para aplicar")
	_apply_button.disabled = false


func _slice_animation_sheet(sheet: Image, frame_count: int) -> Array[Image]:
	var frames: Array[Image] = []
	for frame_index in frame_count:
		var start_x := roundi(float(frame_index * sheet.get_width()) / float(frame_count))
		var end_x := roundi(float((frame_index + 1) * sheet.get_width()) / float(frame_count))
		var frame := sheet.get_region(Rect2i(start_x, 0, end_x - start_x, sheet.get_height()))
		frame.resize(
			_request_source_image.get_width(),
			_request_source_image.get_height(),
			Image.INTERPOLATE_NEAREST
		)
		_remove_generated_background(frame)
		frames.append(frame)
	return frames


func _remove_generated_background(image: Image) -> void:
	image.convert(Image.FORMAT_RGBA8)
	var width := image.get_width()
	var height := image.get_height()
	for x in width:
		if image.get_pixel(x, 0).a < 0.95 or image.get_pixel(x, height - 1).a < 0.95:
			return
	for y in height:
		if image.get_pixel(0, y).a < 0.95 or image.get_pixel(width - 1, y).a < 0.95:
			return

	var corner_colors := [
		image.get_pixel(0, 0),
		image.get_pixel(width - 1, 0),
		image.get_pixel(0, height - 1),
		image.get_pixel(width - 1, height - 1)
	]
	var visited := PackedByteArray()
	visited.resize(width * height)
	var queue: Array[Vector2i] = []
	for x in width:
		_queue_background_pixel(Vector2i(x, 0), image, corner_colors, visited, queue)
		_queue_background_pixel(Vector2i(x, height - 1), image, corner_colors, visited, queue)
	for y in height:
		_queue_background_pixel(Vector2i(0, y), image, corner_colors, visited, queue)
		_queue_background_pixel(Vector2i(width - 1, y), image, corner_colors, visited, queue)

	var read_index := 0
	var neighbors := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
	while read_index < queue.size():
		var point := queue[read_index]
		read_index += 1
		image.set_pixel(point.x, point.y, Color.TRANSPARENT)
		for direction in neighbors:
			var next_point: Vector2i = point + direction
			if next_point.x < 0 or next_point.x >= width or next_point.y < 0 or next_point.y >= height:
				continue
			_queue_background_pixel(next_point, image, corner_colors, visited, queue)


func _queue_background_pixel(
	point: Vector2i,
	image: Image,
	background_colors: Array,
	visited: PackedByteArray,
	queue: Array[Vector2i]
) -> void:
	var index := point.y * image.get_width() + point.x
	if visited[index] == 1:
		return
	visited[index] = 1
	var color := image.get_pixel(point.x, point.y)
	for background_color: Color in background_colors:
		var difference := Vector3(color.r, color.g, color.b).distance_to(
			Vector3(background_color.r, background_color.g, background_color.b)
		)
		if difference <= 0.16:
			queue.append(point)
			return


func _on_request_failed(message: String) -> void:
	_set_busy(false, "Falha na solicitação")
	_pending_generated_frames.clear()
	_show_error(message)


func _on_apply_pressed() -> void:
	if _pending_response.is_empty() and _pending_generated_frames.is_empty():
		return
	if not _pending_generated_frames.is_empty():
		_confirm_dialog.dialog_text = "Adicionar %d quadros gerados pelo Nano Banana?" % (
			_pending_generated_frames.size()
		)
		_confirm_dialog.popup_centered()
		return
	var operations: Array = _pending_response.get("operations", [])
	var animation_frames: Array = _pending_response.get("animation_frames", [])
	_confirm_dialog.dialog_text = (
		"Aplicar %d operação(ões) e gerar %d quadro(s) de animação?"
		% [operations.size(), animation_frames.size()]
	)
	_confirm_dialog.popup_centered()


func _apply_pending_response() -> void:
	if _request_project != extension_api.project.current_project:
		_show_error("O projeto ativo mudou. Solicite uma nova proposta.")
		return
	var project = _request_project
	if _request_frame < 0 or _request_frame >= project.frames.size():
		_show_error("O quadro de destino não existe mais.")
		return
	if _request_layer < 0 or _request_layer >= project.layers.size():
		_show_error("A camada de destino não existe mais.")
		return
	var cel = project.frames[_request_frame].cels[_request_layer]
	if cel == null or cel.get_class_name() != "PixelCel":
		_show_error("O destino não é mais uma cel de pixels.")
		return
	var image = cel.get_image()
	if hash(image.get_data()) != _request_image_hash:
		_show_error("A cel original mudou. Solicite uma nova proposta de animação.")
		return
	if not _pending_generated_frames.is_empty():
		_insert_generated_frames(project, _pending_generated_frames)
		var generated_count := _pending_generated_frames.size()
		_pending_generated_frames.clear()
		_apply_button.disabled = true
		_status_label.text = "Animação gerada: %d novo(s) quadro(s)" % generated_count
		return
	var validated := _validate_operations(
		_pending_response.get("operations", []), image.get_width(), image.get_height()
	)
	if not validated.ok:
		_show_error(validated.error)
		return
	var validated_frames := _validate_animation_frames(
		_pending_response.get("animation_frames", []), image.get_width(), image.get_height()
	)
	if not validated_frames.ok:
		_show_error(validated_frames.error)
		return

	if not validated.operations.is_empty():
		_apply_current_operations(project, cel, image, validated.operations)
	if not validated_frames.frames.is_empty():
		_add_animation_frames(project, validated_frames.frames)
	_pending_response.clear()
	_apply_button.disabled = true
	if validated_frames.frames.is_empty():
		_status_label.text = "Alterações aplicadas"
	else:
		_status_label.text = "Animação gerada: %d novo(s) quadro(s)" % validated_frames.frames.size()


func _apply_current_operations(project, cel, image: Image, operations: Array) -> void:
	var undo_data := {}
	image.add_data_to_dictionary(undo_data)
	for operation in operations:
		_execute_operation(image, operation)
	image.convert_rgb_to_indexed()
	var redo_data := {}
	image.add_data_to_dictionary(redo_data)
	project.undo_redo.create_action("Edição de pixels com IA")
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


func _add_animation_frames(project, frames_data: Array) -> void:
	var images: Array[Image] = []
	var names: Array[String] = []
	var durations: Array[float] = []
	for frame_data: Dictionary in frames_data:
		var generated_image: Image = _request_source_image.duplicate()
		for operation in frame_data.operations:
			_execute_operation(generated_image, operation)
		images.append(generated_image)
		names.append(frame_data.name)
		durations.append(frame_data.duration)
	_insert_generated_frames(project, images, names, durations)


func _insert_generated_frames(
	project, images: Array[Image], names: Array[String] = [], durations: Array[float] = []
) -> void:
	var new_frames: Array[Frame] = []
	var indices := PackedInt32Array()
	var source_frame = project.frames[_request_frame]
	for frame_index in images.size():
		var new_frame := Frame.new()
		new_frame.duration = durations[frame_index] if frame_index < durations.size() else 1.0
		var frame_name := (
			names[frame_index]
			if frame_index < names.size()
			else "frame_%d" % (frame_index + 1)
		)
		new_frame.user_data = "AI: %s" % frame_name
		for layer_index in project.layers.size():
			var source_layer_cel = source_frame.cels[layer_index]
			var new_cel = source_layer_cel.duplicate_cel()
			if layer_index == _request_layer:
				var generated_image: Image = images[frame_index].duplicate()
				generated_image.convert(project.get_image_format())
				if generated_image is ImageExtended:
					generated_image.convert_rgb_to_indexed()
				new_cel.set_content(generated_image)
			else:
				new_cel.set_content(source_layer_cel.copy_content())
			new_frame.cels.append(new_cel)
		new_frames.append(new_frame)
		indices.append(_request_frame + frame_index + 1)

	var previous_frame: int = project.current_frame
	var previous_layer: int = project.current_layer
	project.undo_redo.create_action("Gerar animação com IA")
	project.undo_redo.add_do_property(project, "selected_cels", [])
	project.undo_redo.add_undo_property(project, "selected_cels", [])
	project.undo_redo.add_do_method(project.add_frames.bind(new_frames, indices))
	project.undo_redo.add_do_method(project.change_cel.bind(indices[0], _request_layer))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false, -1, -1, project))
	project.undo_redo.add_undo_method(project.remove_frames.bind(indices))
	project.undo_redo.add_undo_method(project.change_cel.bind(previous_frame, previous_layer))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true, -1, -1, project))
	project.undo_redo.commit_action()


func _validate_operations(operations, width: int, height: int) -> Dictionary:
	if typeof(operations) != TYPE_ARRAY or operations.size() > 64:
		return {"ok": false, "error": "Lista de operações inválida."}
	var validated: Array[Dictionary] = []
	var changed_pixels := 0
	for operation in operations:
		if typeof(operation) != TYPE_DICTIONARY:
			return {"ok": false, "error": "Operação inválida."}
		match operation.get("type", ""):
			"set_pixels":
				var pixels = operation.get("pixels", [])
				if typeof(pixels) != TYPE_ARRAY:
					return {"ok": false, "error": "Lista de pixels inválida."}
				var valid_pixels: Array[Dictionary] = []
				for pixel in pixels:
					if typeof(pixel) != TYPE_DICTIONARY:
						return {"ok": false, "error": "Entrada de pixel inválida."}
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
							"error": "O pixel está fora da tela ou possui uma cor inválida."
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
						"error": "O retângulo está fora da tela ou possui uma cor inválida."
					}
				changed_pixels += rect_width * rect_height
				validated.append(
					{
						"type": "fill_rect",
						"rect": Rect2i(x, y, rect_width, rect_height),
						"color": color
					}
				)
			"copy_rect":
				var source_rect := Rect2i(
					int(operation.get("x", -1)),
					int(operation.get("y", -1)),
					int(operation.get("width", 0)),
					int(operation.get("height", 0))
				)
				var destination := Vector2i(
					int(operation.get("to_x", -1)), int(operation.get("to_y", -1))
				)
				var destination_rect := Rect2i(destination, source_rect.size)
				var canvas_rect := Rect2i(0, 0, width, height)
				if (
					source_rect.size.x <= 0
					or source_rect.size.y <= 0
					or not canvas_rect.encloses(source_rect)
					or not canvas_rect.encloses(destination_rect)
				):
					return {"ok": false, "error": "O retângulo copiado está fora da tela."}
				changed_pixels += source_rect.get_area() * 2
				validated.append(
					{
						"type": "copy_rect",
						"rect": source_rect,
						"destination": destination,
						"clear": bool(operation.get("clear", true))
					}
				)
			_:
				return {"ok": false, "error": "Operação de IA não suportada."}
		if changed_pixels > MAX_CHANGED_PIXELS:
			return {"ok": false, "error": "A proposta da IA altera pixels demais."}
	return {"ok": true, "operations": validated}


func _validate_animation_frames(frames, width: int, height: int) -> Dictionary:
	if typeof(frames) != TYPE_ARRAY or frames.size() > 8:
		return {"ok": false, "error": "A animação deve conter no máximo 8 quadros."}
	if not frames.is_empty() and frames.size() < 2:
		return {"ok": false, "error": "A animação deve conter pelo menos 2 quadros."}
	var validated_frames: Array[Dictionary] = []
	for frame_index in frames.size():
		var frame = frames[frame_index]
		if typeof(frame) != TYPE_DICTIONARY:
			return {"ok": false, "error": "Quadro de animação inválido."}
		var validated := _validate_operations(frame.get("operations", []), width, height)
		if not validated.ok:
			return {"ok": false, "error": "Quadro %d: %s" % [frame_index + 1, validated.error]}
		if validated.operations.is_empty():
			return {"ok": false, "error": "Os quadros da animação devem conter alterações visíveis."}
		validated_frames.append(
			{
				"name": str(frame.get("name", "frame_%d" % (frame_index + 1))).left(64),
				"duration": clampf(float(frame.get("duration", 1.0)), 0.1, 10.0),
				"operations": validated.operations
			}
		)
	return {"ok": true, "frames": validated_frames}


func _execute_operation(image: Image, operation: Dictionary) -> void:
	match operation.type:
		"set_pixels":
			for pixel in operation.pixels:
				image.set_pixel(pixel.x, pixel.y, Color.from_string(pixel.color, Color.TRANSPARENT))
		"fill_rect":
			image.fill_rect(operation.rect, Color.from_string(operation.color, Color.TRANSPARENT))
		"copy_rect":
			var copied_region := image.get_region(operation.rect)
			if operation.clear:
				image.fill_rect(operation.rect, Color.TRANSPARENT)
			image.blit_rect(
				copied_region,
				Rect2i(Vector2i.ZERO, copied_region.get_size()),
				operation.destination
			)


func _set_busy(busy: bool, status: String) -> void:
	_send_button.disabled = busy
	_status_label.text = status


func _show_error(message: String) -> void:
	_status_label.text = message
	_result_label.text = "[color=red]%s[/color]" % _escape_bbcode(message)


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")
