extends HBoxContainer
## Wrapper around the embedded Tools panel (above the timeline controls).
##
## Adds a "⋮" options button that can pop the tools out into a floating window
## and dock them back, mimicking the option the Tools panel had while it was a
## dockable tab. The Tools node is reparented (not duplicated), so the Tools
## autoload keeps working on the same buttons.

const FLOAT_ID := 0

@onready var tools: Control = $Tools
@onready var options_button: Button = $OptionsButton

var _menu: PopupMenu
var _window: Window
## Child index the Tools node sits at while docked, so it returns to the same
## spot (left of the options button).
var _home_index := 0


func _ready() -> void:
	_home_index = tools.get_index()
	_menu = PopupMenu.new()
	_menu.add_check_item("Floating", FLOAT_ID)
	_menu.id_pressed.connect(_on_menu_id_pressed)
	options_button.add_child(_menu)
	options_button.pressed.connect(_show_menu)


func _show_menu() -> void:
	_menu.set_item_checked(_menu.get_item_index(FLOAT_ID), is_instance_valid(_window))
	_menu.reset_size()
	_menu.position = options_button.get_screen_position() + Vector2(0, options_button.size.y)
	_menu.popup()


func _on_menu_id_pressed(id: int) -> void:
	if id == FLOAT_ID:
		if is_instance_valid(_window):
			_dock_back()
		else:
			_make_floating()


func _make_floating() -> void:
	_window = Window.new()
	_window.title = "Tools"
	_window.size = Vector2i(280, 90)
	_window.min_size = Vector2i(120, 48)
	_window.transient = true
	_window.close_requested.connect(_dock_back)
	add_child(_window)
	# Reparent the live Tools node into the window; keep one instance so the
	# Tools autoload references (cached ToolButtons node) stay valid.
	tools.reparent(_window)
	tools.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_window.popup_centered()


func _dock_back() -> void:
	if not is_instance_valid(_window):
		return
	if is_instance_valid(tools):
		tools.reparent(self)
		move_child(tools, _home_index)
		tools.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		tools.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tools.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_window.queue_free()
	_window = null
