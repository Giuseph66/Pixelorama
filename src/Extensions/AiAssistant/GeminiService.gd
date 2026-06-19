extends Node

signal request_succeeded(response: Dictionary)
signal image_request_succeeded(
	image_data: PackedByteArray, mime_type: String, description: String, frame_count: int
)
signal request_failed(message: String)

const API_URL := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
const IMAGE_API_URL := "https://generativelanguage.googleapis.com/v1/models/%s:generateContent"
const ALLOWED_IMAGE_MIME_TYPES := ["image/png", "image/jpeg", "image/webp"]
const MAX_GENERATED_IMAGE_BYTES := 48 * 1024 * 1024
const SYSTEM_INSTRUCTION := """
You are Pixelorama's pixel-art editor and animation generator. Analyze the current cel and perform
the user's request through safe pixel operations. Preserve canvas dimensions, palette, transparency,
silhouette, lighting direction, and pixel-art style. Colors must be #RRGGBBAA. Never address pixels
outside the canvas.

If the user requests animation, movement, walking, attacking, idling, or multiple sprites, you MUST
generate animation_frames. Never claim that you cannot generate animation. Generate 4 frames unless
the user requests another count, with a maximum of 8. Every animation frame starts as a copy of the
supplied cel, so describe only changes from that source. Make poses visibly different while keeping
the character recognizable. Alternate limbs and add subtle body motion for walk cycles.

Return exactly one JSON object with this shape:
{"message":"short explanation","operations":[],"animation_frames":[]}
A set_pixels operation is:
{"type":"set_pixels","pixels":[{"x":0,"y":0,"color":"#RRGGBBAA"}]}
A fill_rect operation is:
{"type":"fill_rect","x":0,"y":0,"width":1,"height":1,"color":"#RRGGBBAA"}
A copy_rect operation copies or moves an existing rectangular region:
{"type":"copy_rect","x":0,"y":0,"width":1,"height":1,"to_x":1,"to_y":1,"clear":true}
An animation frame is:
{"name":"walk_1","duration":1.0,"operations":[...]}
For analysis-only requests, return empty operations and animation_frames.
"""

var _http: HTTPRequest
var _api_key := ""
var _model := "gemini-2.5-flash"
var _image_model := "gemini-3.1-flash-image"
var _busy := false
var _is_image_request := false
var _requested_frame_count := 0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 90.0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func configure(api_key: String, model: String, image_model := "") -> void:
	_api_key = api_key.strip_edges()
	_model = model.strip_edges()
	if _model.is_empty():
		_model = "gemini-2.5-flash"
	_image_model = image_model.strip_edges()
	if _image_model.is_empty():
		_image_model = "gemini-3.1-flash-image"


func is_busy() -> bool:
	return _busy


func analyze_cel(prompt: String, image: Image, context: Dictionary) -> void:
	if not _validate_request(prompt, image):
		return
	var png_data := image.save_png_to_buffer()
	# Base64 adds overhead; keep the complete request below Gemini's 20 MB inline limit.
	if png_data.size() > 14 * 1024 * 1024:
		request_failed.emit("A cel atual é grande demais para uma solicitação Gemini inline.")
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
			"temperature": 0.35,
			"thinkingConfig": {"thinkingBudget": 1024},
			"responseMimeType": "application/json"
		}
	}
	var headers := PackedStringArray(
		["Content-Type: application/json", "x-goog-api-key: %s" % _api_key]
	)
	_is_image_request = false
	_requested_frame_count = 0
	_http.timeout = 90.0
	_start_request(API_URL % _model.uri_encode(), headers, body)


func generate_animation_sheet(
	prompt: String, image: Image, context: Dictionary, frame_count := 4
) -> void:
	if not _validate_request(prompt, image):
		return
	frame_count = clampi(frame_count, 2, 8)
	var png_data := image.save_png_to_buffer()
	if png_data.size() > 14 * 1024 * 1024:
		request_failed.emit("A cel atual é grande demais para uma solicitação Gemini inline.")
		return
	var sheet_ratio := float(image.get_width() * frame_count) / float(image.get_height())
	var aspect_ratio := "8:1" if sheet_ratio >= 6.0 else "4:1"
	var generation_prompt := """
Use the supplied character image as the strict visual reference. Create exactly %d consecutive
animation frames for this request: %s

Return one horizontal spritesheet in one row with exactly %d equal-width cells. Use a transparent
background without checkerboard, labels, borders, gaps, guides, text, shadows, or extra objects.
Show the entire character in every cell on one consistent ground baseline. Preserve identity,
anatomy, proportions, colors, outlines, rendering style, and lighting. Change only the pose needed
for fluid animation. The first and last poses must connect as a seamless loop.

Output aspect ratio: %s. Source canvas: %dx%d. Context: %s
""" % [
		frame_count,
		prompt.strip_edges(),
		frame_count,
		aspect_ratio,
		image.get_width(),
		image.get_height(),
		JSON.stringify(context)
	]
	var body := {
		"contents": [
			{
				"role": "user",
				"parts": [
					{"text": generation_prompt},
					{
						"inline_data": {
							"mime_type": "image/png",
							"data": Marshalls.raw_to_base64(png_data)
						}
					}
				]
			}
		]
	}
	var headers := PackedStringArray(
		["Content-Type: application/json", "x-goog-api-key: %s" % _api_key]
	)
	_is_image_request = true
	_requested_frame_count = frame_count
	_http.timeout = 180.0
	_start_request(IMAGE_API_URL % _image_model.uri_encode(), headers, body)


func _validate_request(prompt: String, image: Image) -> bool:
	if _busy:
		request_failed.emit("Já existe uma solicitação em andamento.")
		return false
	if _api_key.is_empty():
		request_failed.emit("Configure a chave Gemini em Preferências > IA.")
		return false
	if prompt.strip_edges().is_empty():
		request_failed.emit("Descreva o que o assistente deve fazer.")
		return false
	if image == null or image.is_empty():
		request_failed.emit("A cel atual não possui dados de imagem.")
		return false
	return true


func _start_request(url: String, headers: PackedStringArray, body: Dictionary) -> void:
	_busy = true
	var error := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		_busy = false
		request_failed.emit("Não foi possível iniciar a solicitação Gemini: %s" % error_string(error))


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	_busy = false
	var data = JSON.parse_string(body.get_string_from_utf8())
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("A solicitação Gemini falhou: %s" % result)
		return
	if typeof(data) != TYPE_DICTIONARY:
		request_failed.emit("O Gemini retornou uma resposta inválida.")
		return
	if response_code < 200 or response_code >= 300:
		var error_data = data.get("error", {})
		request_failed.emit(str(error_data.get("message", "Erro HTTP do Gemini: %s" % response_code)))
		return

	var candidates = data.get("candidates", [])
	if typeof(candidates) != TYPE_ARRAY or candidates.is_empty():
		request_failed.emit("O Gemini não retornou candidatos.")
		return
	var content = candidates[0].get("content", {})
	var parts = content.get("parts", [])
	if typeof(parts) != TYPE_ARRAY or parts.is_empty():
		request_failed.emit("O Gemini não retornou conteúdo.")
		return
	if _is_image_request:
		_parse_image_response(parts)
		return
	var response_text := ""
	for part in parts:
		if typeof(part) == TYPE_DICTIONARY and not part.get("thought", false):
			response_text += str(part.get("text", ""))
	var parsed = JSON.parse_string(response_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		var finish_reason := str(candidates[0].get("finishReason", "unknown"))
		request_failed.emit(
			"O Gemini retornou JSON inválido (fim: %s, caracteres: %d)."
			% [finish_reason, response_text.length()]
		)
		return
	request_succeeded.emit(parsed)


func _parse_image_response(parts: Array) -> void:
	var image_data := PackedByteArray()
	var mime_type := ""
	var description := ""
	for part in parts:
		if typeof(part) != TYPE_DICTIONARY or part.get("thought", false):
			continue
		if part.has("text"):
			description += str(part.text)
		var inline_data = part.get("inlineData", part.get("inline_data", {}))
		if typeof(inline_data) != TYPE_DICTIONARY:
			continue
		var candidate_mime := str(inline_data.get("mimeType", inline_data.get("mime_type", "")))
		var encoded_data := str(inline_data.get("data", ""))
		if candidate_mime in ALLOWED_IMAGE_MIME_TYPES and not encoded_data.is_empty():
			var decoded := Marshalls.base64_to_raw(encoded_data)
			if not decoded.is_empty() and decoded.size() <= MAX_GENERATED_IMAGE_BYTES:
				image_data = decoded
				mime_type = candidate_mime
	if image_data.is_empty():
		request_failed.emit("O Nano Banana não retornou uma imagem válida.")
		return
	image_request_succeeded.emit(
		image_data, mime_type, description.strip_edges(), _requested_frame_count
	)
