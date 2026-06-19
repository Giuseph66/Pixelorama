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

enum { MENU_OPEN, MENU_NEW_FRAME, MENU_NEW_LAYER }

var extension_api: Node  # /root/ExtensionsApi
var root_dir := ""

var _panel: Control
var _path_label: Label
var _tree: Tree
var _menu: PopupMenu
var _menu_target_path := ""
var _show_hidden := false


func _enter_tree() -> void:
	extension_api = get_node_or_null("/root/ExtensionsApi")
	_panel = _build_panel()
	# node.name is used as the tab title.
	if extension_api:
		extension_api.panel.add_node_as_tab(_panel)


func _exit_tree() -> void:
	if extension_api and is_instance_valid(_panel):
		extension_api.panel.remove_node_from_tab(_panel)
	if is_instance_valid(_panel):
		_panel.queue_free()


func _build_panel() -> Control:
	var panel := Control.new()
	panel.name = "Folder Browser"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(vbox)

	var toolbar := HBoxContainer.new()
	vbox.add_child(toolbar)

	var open_btn := Button.new()
	open_btn.text = "Open Folder"
	open_btn.pressed.connect(_on_open_folder_pressed)
	toolbar.add_child(open_btn)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(_populate_tree)
	toolbar.add_child(refresh_btn)

	_path_label = Label.new()
	_path_label.text = "No folder opened"
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_label.clip_text = true
	toolbar.add_child(_path_label)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.allow_rmb_select = true
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_mouse_selected.connect(_on_item_mouse_selected)
	vbox.add_child(_tree)

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu_id_pressed)
	panel.add_child(_menu)

	return panel


func _on_open_folder_pressed() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.dir_selected.connect(_on_dir_selected)
	dialog.close_requested.connect(dialog.queue_free)
	_panel.add_child(dialog)
	dialog.popup_centered(Vector2i(700, 500))


func _on_dir_selected(dir: String) -> void:
	root_dir = dir
	_path_label.text = dir
	_path_label.tooltip_text = dir
	_populate_tree()


func _populate_tree() -> void:
	_tree.clear()
	if root_dir.is_empty():
		return
	var root_item := _tree.create_item()
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
		# Eagerly recurse so the native fold arrow only appears when there is
		# actually something inside (no empty placeholder rows).
		_add_dir_to_tree(folder_path, item, depth + 1)
		item.collapsed = true

	for file in files:
		var item := _tree.create_item(parent)
		item.set_text(0, file)
		item.set_metadata(0, {"type": "file", "path": path.path_join(file)})


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
	_menu.add_item("Open", MENU_OPEN)
	# .pxo is a project file, not a raster image, so it can't become a frame/layer.
	if _menu_target_path.get_extension().to_lower() != "pxo":
		_menu.add_item("Add as new frame", MENU_NEW_FRAME)
		_menu.add_item("Add as new layer", MENU_NEW_LAYER)
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
		push_warning("Folder Browser: failed to load image %s" % path)
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
