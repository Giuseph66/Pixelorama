extends Node

signal request_succeeded(response: Dictionary)
signal request_failed(message: String)

const API_URL := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
const SYSTEM_INSTRUCTION := """
You are Pixelorama's pixel-art editing assistant. Analyze the current cel and the user's request.
Return a short explanation and only safe pixel-level operations. Preserve canvas dimensions and
pixel-art style. Colors must be #RRGGBBAA. Use set_pixels for sparse edits and fill_rect for solid
regions. Never address pixels outside the canvas. Return no operations when the user only asks for
analysis or when the request is ambiguous.
"""
const RESPONSE_SCHEMA := {
	"type": "object",
	"properties": {
		"message": {"type": "string"},
		"operations": {
			"type": "array",
			"maxItems": 64,
			"items": {
				"type": "object",
				"properties": {
					"type": {"type": "string", "enum": ["set_pixels", "fill_rect"]},
					"pixels": {
						"type": "array",
						"maxItems": 4096,
						"items": {
							"type": "object",
							"properties": {
								"x": {"type": "integer"},
								"y": {"type": "integer"},
								"color": {"type": "string"}
							},
							"required": ["x", "y", "color"]
						}
					},
					"x": {"type": "integer"},
					"y": {"type": "integer"},
					"width": {"type": "integer", "minimum": 1},
					"height": {"type": "integer", "minimum": 1},
					"color": {"type": "string"}
				},
				"required": ["type"]
			}
		}
	},
	"required": ["message", "operations"]
}

var _http: HTTPRequest
var _api_key := ""
var _model := "gemini-2.5-flash"
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 90.0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func configure(api_key: String, model: String) -> void:
	_api_key = api_key.strip_edges()
	_model = model.strip_edges()
	if _model.is_empty():
		_model = "gemini-2.5-flash"


func is_busy() -> bool:
	return _busy


func analyze_cel(prompt: String, image: Image, context: Dictionary) -> void:
	if _busy:
		request_failed.emit("A request is already running.")
		return
	if _api_key.is_empty():
		request_failed.emit("Set GEMINI_API_KEY or enter an API key.")
		return
	if prompt.strip_edges().is_empty():
		request_failed.emit("Describe what the assistant should do.")
		return
	if image == null or image.is_empty():
		request_failed.emit("The current cel has no image data.")
		return
	var png_data := image.save_png_to_buffer()
	# Base64 adds overhead; keep the complete request below Gemini's 20 MB inline limit.
	if png_data.size() > 14 * 1024 * 1024:
		request_failed.emit("The current cel is too large for an inline Gemini request.")
		return

	var context_text := "%s\n\nCanvas context: %s" % [prompt.strip_edges(), JSON.stringify(context)]
	var body := {
		"system_instruction": {"parts": [{"text": SYSTEM_INSTRUCTION}]},
		"contents": [
			{
				"role": "user",
				"parts": [
					{"text": context_text},
					{
						"inline_data": {
							"mime_type": "image/png",
							"data": Marshalls.raw_to_base64(png_data)
						}
					}
				]
			}
		],
		"generationConfig": {
			"temperature": 0.2,
			"responseFormat": {
				"text": {"mimeType": "application/json", "schema": RESPONSE_SCHEMA}
			}
		}
	}
	var headers := PackedStringArray(
		["Content-Type: application/json", "x-goog-api-key: %s" % _api_key]
	)
	_busy = true
	var error := _http.request(
		API_URL % _model.uri_encode(), headers, HTTPClient.METHOD_POST, JSON.stringify(body)
	)
	if error != OK:
		_busy = false
		request_failed.emit("Could not start Gemini request: %s" % error_string(error))


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	_busy = false
	var data = JSON.parse_string(body.get_string_from_utf8())
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("Gemini request failed: %s" % result)
		return
	if typeof(data) != TYPE_DICTIONARY:
		request_failed.emit("Gemini returned an invalid response.")
		return
	if response_code < 200 or response_code >= 300:
		var error_data = data.get("error", {})
		request_failed.emit(str(error_data.get("message", "Gemini HTTP error %s" % response_code)))
		return

	var candidates = data.get("candidates", [])
	if typeof(candidates) != TYPE_ARRAY or candidates.is_empty():
		request_failed.emit("Gemini returned no candidates.")
		return
	var content = candidates[0].get("content", {})
	var parts = content.get("parts", [])
	if typeof(parts) != TYPE_ARRAY or parts.is_empty():
		request_failed.emit("Gemini returned no content.")
		return
	var response_text := ""
	for part in parts:
		if typeof(part) == TYPE_DICTIONARY:
			response_text += str(part.get("text", ""))
	var parsed = JSON.parse_string(response_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		request_failed.emit("Gemini returned invalid structured output.")
		return
	request_succeeded.emit(parsed)
