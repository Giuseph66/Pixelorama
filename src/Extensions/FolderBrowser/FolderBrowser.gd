extends Node
## Folder Browser extension for Pixelorama.
##
## Adds a dockable panel that lets you pick a root folder ("Open Folder") and
## browse its files in a tree. Double-clicking a supported file opens it in
## Pixelorama, so you can navigate a project's animations without fighting the
## modal file dialog.
##
## This root node is just a controller: it stays parented to the Extensions
## handler and registers a separate [Control] as the actual dockable tab. That
## avoids reparenting an already-parented node into the DockableContainer.

const SUPPORTED_EXTENSIONS := ["pxo", "png", "jpg", "jpeg", "bmp", "webp", "gif", "tga"]
const MAX_DEPTH := 12
const CONFIG_SECTION := "folder_browser"
const CONFIG_ROOT_DIR := "root_dir"
const ICONS_PATH := "res://src/Extensions/FolderBrowser/icons/"

enum { MENU_OPEN, MENU_NEW_FRAME, MENU_NEW_LAYER }

var extension_api: Node  # /root/ExtensionsApi
var root_dir := ""

var _panel: Control
var _header_label: Label
var _tree: Tree
var _empty_state: CenterContainer
var _menu: PopupMenu
var _menu_target_path := ""
var _show_hidden := false
var _icons := {}


func _enter_tree() -> void:
	extension_api = get_node_or_null("/root/ExtensionsApi")
	_init_icons()
	_panel = _build_panel()
	# node.name is used as the tab title.
	if extension_api:
		extension_api.panel.add_node_as_tab(_panel)
	_restore_last_folder()


func _exit_tree() -> void:
	if extension_api and is_instance_valid(_panel):
		extension_api.panel.remove_node_from_tab(_panel)
	if is_instance_valid(_panel):
		_panel.queue_free()


func _init_icons() -> void:
	var keys := [
		"folder_closed", "folder_open", "file_generic",
		"file_json", "file_gd", "file_tscn",
		"file_image", "file_pxo", "action_refresh", "action_open"
	]
	for key in keys:
		var path := ICONS_PATH.path_join(key + ".svg")
		if ResourceLoader.exists(path):
			_icons[key] = load(path)


func _get_file_icon(file_name: String) -> Texture2D:
	var ext := file_name.get_extension().to_lower()
	match ext:
		"json":
			return _icons.get("file_json")
		"gd":
			return _icons.get("file_gd")
		"tscn":
			return _icons.get("file_tscn")
		"pxo":
			return _icons.get("file_pxo")
		"png", "jpg", "jpeg", "bmp", "webp", "gif", "tga":
			return _icons.get("file_image")
		_:
			return _icons.get("file_generic")


func _build_panel() -> Control:
	var panel := Control.new()
	panel.name = "Pastas"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 0)
	panel.add_child(main_vbox)

	# 1. Header Bar (VS Code style)
	var header_panel := PanelContainer.new()
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = Color(0.08, 0.08, 0.08, 0.9)  # Dark VS Code header background
	header_style.content_margin_left = 8
	header_style.content_margin_right = 8
	header_style.content_margin_top = 4
	header_style.content_margin_bottom = 4
	header_panel.add_theme_stylebox_override("panel", header_style)
	main_vbox.add_child(header_panel)

	var header_hbox := HBoxContainer.new()
	header_panel.add_child(header_hbox)

	_header_label = Label.new()
	_header_label.text = "EXPLORER"
	_header_label.add_theme_font_size_override("font_size", 10)
	_header_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_label.clip_text = true
	header_hbox.add_child(_header_label)

	var open_btn := Button.new()
	open_btn.flat = true
	open_btn.custom_minimum_size = Vector2(20, 20)
	open_btn.icon = _icons.get("action_open")
	open_btn.tooltip_text = "Abrir Pasta"
	open_btn.pressed.connect(_on_open_folder_pressed)
	header_hbox.add_child(open_btn)

	var refresh_btn := Button.new()
	refresh_btn.flat = true
	refresh_btn.custom_minimum_size = Vector2(20, 20)
	refresh_btn.icon = _icons.get("action_refresh")
	refresh_btn.tooltip_text = "Atualizar"
	refresh_btn.pressed.connect(_populate_tree)
	header_hbox.add_child(refresh_btn)

	# 2. Main Content Area (contains Tree and Empty State)
	var content_container := MarginContainer.new()
	content_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(content_container)

	# Tree
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = false
	_tree.select_mode = Tree.SELECT_ROW
	_tree.allow_rmb_select = true
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_mouse_selected.connect(_on_item_mouse_selected)
	_tree.item_collapsed.connect(_on_item_collapsed)

	# VS Code Explorer styling
	_tree.add_theme_constant_override("relationship_line_width", 1)
	_tree.add_theme_constant_override("draw_relationship_lines", 1)
	_tree.add_theme_color_override("relationship_line_color", Color(0.3, 0.3, 0.3, 0.4))
	_tree.add_theme_constant_override("indent", 12)
	_tree.add_theme_constant_override("v_separation", 4)

	content_container.add_child(_tree)

	# Empty State
	_empty_state = CenterContainer.new()
	_empty_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_state.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_container.add_child(_empty_state)

	var empty_vbox := VBoxContainer.new()
	_empty_state.add_child(empty_vbox)

	var empty_label := Label.new()
	empty_label.text = "Nenhuma pasta aberta."
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	empty_vbox.add_child(empty_label)

	var empty_btn := Button.new()
	empty_btn.text = "Abrir Pasta"
	empty_btn.pressed.connect(_on_open_folder_pressed)
	empty_vbox.add_child(empty_btn)

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu_id_pressed)
	panel.add_child(_menu)

	return panel


func _show_empty_state(show: bool) -> void:
	if is_instance_valid(_empty_state):
		_empty_state.visible = show
	if is_instance_valid(_tree):
		_tree.visible = not show


func _on_open_folder_pressed() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.dir_selected.connect(_on_dir_selected)
	dialog.close_requested.connect(dialog.queue_free)
	_panel.add_child(dialog)
	if not root_dir.is_empty() and DirAccess.dir_exists_absolute(root_dir):
		dialog.current_dir = root_dir
	dialog.popup_centered(Vector2i(700, 500))


func _on_dir_selected(dir: String) -> void:
	root_dir = dir
	if is_instance_valid(_header_label):
		_header_label.text = dir.get_file().to_upper()
		_header_label.tooltip_text = dir
	Global.config_cache.set_value(CONFIG_SECTION, CONFIG_ROOT_DIR, dir)
	Global.config_cache.save(Global.CONFIG_PATH)
	_populate_tree()


func _restore_last_folder() -> void:
	var saved_dir: String = Global.config_cache.get_value(CONFIG_SECTION, CONFIG_ROOT_DIR, "")
	if saved_dir.is_empty() or not DirAccess.dir_exists_absolute(saved_dir):
		_show_empty_state(true)
		return
	root_dir = saved_dir
	if is_instance_valid(_header_label):
		_header_label.text = saved_dir.get_file().to_upper()
		_header_label.tooltip_text = saved_dir
	_populate_tree()


func _populate_tree() -> void:
	_tree.clear()
	if root_dir.is_empty():
		_show_empty_state(true)
		return

	_show_empty_state(false)

	if is_instance_valid(_header_label):
		_header_label.text = root_dir.get_file().to_upper()
		_header_label.tooltip_text = root_dir

	var root_item := _tree.create_item()
	root_item.set_text(0, root_dir.get_file())
	root_item.set_metadata(0, {"type": "dir", "path": root_dir})
	root_item.set_icon(0, _icons.get("folder_open"))
	root_item.collapsed = false

	_add_dir_to_tree(root_dir, root_item, 0)


## Recursively fills [param parent] with the contents of [param path].
## [param depth] guards against pathologically deep trees / symlink loops.
func _add_dir_to_tree(path: String, parent: TreeItem, depth: int) -> void:
	if depth > MAX_DEPTH:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = _show_hidden
	dir.list_dir_begin()
	var folders: Array[String] = []
	var files: Array[String] = []
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			folders.append(entry)
		elif entry.get_extension().to_lower() in SUPPORTED_EXTENSIONS:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	folders.sort()
	files.sort()

	for folder in folders:
		var folder_path := path.path_join(folder)
		var item := _tree.create_item(parent)
		item.set_text(0, folder)
		item.set_metadata(0, {"type": "dir", "path": folder_path})
		item.set_icon(0, _icons.get("folder_closed"))
		# Eagerly recurse so the native fold arrow only appears when there is
		# actually something inside (no empty placeholder rows).
		_add_dir_to_tree(folder_path, item, depth + 1)
		item.collapsed = true

	for file in files:
		var item := _tree.create_item(parent)
		item.set_text(0, file)
		item.set_metadata(0, {"type": "file", "path": path.path_join(file)})
		item.set_icon(0, _get_file_icon(file))


func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	match meta.get("type"):
		"dir":
			item.collapsed = not item.collapsed
		"file":
			_open_file(meta["path"])


func _on_item_collapsed(item: TreeItem) -> void:
	var meta = item.get_metadata(0)
	if typeof(meta) == TYPE_DICTIONARY and meta.get("type") == "dir":
		if item.collapsed:
			item.set_icon(0, _icons.get("folder_closed"))
		else:
			item.set_icon(0, _icons.get("folder_open"))


func _on_item_mouse_selected(_pos: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := _tree.get_selected()
	if item == null:
		return
	var meta = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY or meta.get("type") != "file":
		return
	_menu_target_path = meta["path"]
	_menu.clear()
	_menu.add_item("Abrir", MENU_OPEN)
	# .pxo is a project file, not a raster image, so it can't become a frame/layer.
	if _menu_target_path.get_extension().to_lower() != "pxo":
		_menu.add_item("Adicionar como novo quadro", MENU_NEW_FRAME)
		_menu.add_item("Adicionar como nova camada", MENU_NEW_LAYER)
	_menu.reset_size()
	_menu.position = get_window().position + Vector2i(_panel.get_viewport().get_mouse_position())
	_menu.popup()


func _on_menu_id_pressed(id: int) -> void:
	match id:
		MENU_OPEN:
			_open_file(_menu_target_path)
		MENU_NEW_FRAME:
			_add_image(_menu_target_path, true)
		MENU_NEW_LAYER:
			_add_image(_menu_target_path, false)


## Loads [param path] as a raster image and adds it to the current project,
## either as a new frame (on the current layer) or as a new layer.
func _add_image(path: String, as_frame: bool) -> void:
	if not extension_api:
		return
	var image := Image.load_from_file(path)
	if image == null:
		push_warning("Navegador de Pastas: falha ao carregar a imagem %s" % path)
		return
	var open_save = extension_api.import.open_save_autoload()
	if as_frame:
		open_save.open_image_as_new_frame(image, _current_layer_index())
	else:
		open_save.open_image_as_new_layer(image, path.get_file(), _current_frame_index())


func _current_layer_index() -> int:
	var project = _current_project()
	return project.current_layer if project else 0


func _current_frame_index() -> int:
	var project = _current_project()
	return project.current_frame if project else 0


func _current_project():
	var global = get_node_or_null("/root/Global")
	return global.current_project if global else null


func _open_file(path: String) -> void:
	# Route through OpenSave so import dialogs / .pxo handling behave like the
	# normal File->Open flow.
	if extension_api:
		var open_save = extension_api.import.open_save_autoload()
		open_save.handle_loading_file(path, true)
