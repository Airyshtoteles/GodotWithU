@tool
extends RefCounted

## auth_client.gd
##
## Handles authentication for GodotWithU.
## Reads/writes the same settings file used by the Cloud addon
## (user://cloud_settings.cfg) so a token saved there is reused here.
## Verifies the token against the backend before allowing relay connections.

const SETTINGS_PATH := "user://cloud_settings.cfg"
const SETTINGS_SECTION := "backend"
const AUTH_MODE_API_TOKEN := "api_token"
const AUTH_MODE_PASSWORD := "password"
const DEFAULT_BACKEND_URL := "https://studio.godaas.org"

var _bearer_token := ""
var _cookie_header := ""
var _http_parent: Node = null


func attach(http_parent: Node) -> void:
	_http_parent = http_parent


func detach() -> void:
	_http_parent = null
	_bearer_token = ""
	_cookie_header = ""


func get_bearer_token() -> String:
	return _bearer_token


func load_settings() -> Dictionary:
	var settings := {
		"backend_url": DEFAULT_BACKEND_URL,
		"auth_mode": AUTH_MODE_API_TOKEN,
		"identifier": "",
		"api_token": "",
		"backend_project_name": "",
	}
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return settings
	return normalize_settings({
		"backend_url": config.get_value(SETTINGS_SECTION, "backend_url", DEFAULT_BACKEND_URL),
		"auth_mode": config.get_value(SETTINGS_SECTION, "auth_mode", AUTH_MODE_API_TOKEN),
		"identifier": config.get_value(SETTINGS_SECTION, "identifier", ""),
		"api_token": config.get_value(SETTINGS_SECTION, "api_token", ""),
		"backend_project_name": config.get_value(SETTINGS_SECTION, "backend_project_name", ""),
	})


func save_settings(settings: Dictionary) -> Dictionary:
	var normalized := normalize_settings(settings)
	var config := ConfigFile.new()
	config.set_value(SETTINGS_SECTION, "backend_url", normalized.get("backend_url", DEFAULT_BACKEND_URL))
	config.set_value(SETTINGS_SECTION, "auth_mode", normalized.get("auth_mode", AUTH_MODE_API_TOKEN))
	config.set_value(SETTINGS_SECTION, "identifier", normalized.get("identifier", ""))
	config.set_value(SETTINGS_SECTION, "api_token", normalized.get("api_token", ""))
	config.set_value(SETTINGS_SECTION, "backend_project_name", normalized.get("backend_project_name", ""))
	config.save(SETTINGS_PATH)
	return normalized


func normalize_settings(settings: Dictionary) -> Dictionary:
	var auth_mode := String(settings.get("auth_mode", AUTH_MODE_API_TOKEN)).strip_edges().to_lower()
	if auth_mode != AUTH_MODE_PASSWORD:
		auth_mode = AUTH_MODE_API_TOKEN
	return {
		"backend_url": _normalize_backend_url(String(settings.get("backend_url", DEFAULT_BACKEND_URL)).strip_edges()),
		"auth_mode": auth_mode,
		"identifier": String(settings.get("identifier", "")).strip_edges(),
		"api_token": String(settings.get("api_token", "")).strip_edges(),
		"backend_project_name": String(settings.get("backend_project_name", "")).strip_edges(),
	}


func _normalize_backend_url(value: String) -> String:
	var normalized := String(value).strip_edges()
	if normalized.is_empty():
		normalized = DEFAULT_BACKEND_URL
	while normalized.ends_with("/"):
		normalized = normalized.trim_suffix("/")
	return normalized


## Verifies the configured token / session against the backend.
## On success returns {"ok": true, "user": {...}, "token": "<bearer>"}.
## On failure returns {"ok": false, "error": "..."}.
func ensure_authenticated(settings: Dictionary, password: String = "") -> Dictionary:
	var normalized := normalize_settings(settings)
	var auth_mode := String(normalized.get("auth_mode", AUTH_MODE_API_TOKEN))

	if auth_mode == AUTH_MODE_API_TOKEN:
		_cookie_header = ""
		var token := String(normalized.get("api_token", "")).strip_edges()
		if token.is_empty():
			_bearer_token = ""
			return { "ok": false, "error": "API token is required." }
		_bearer_token = token
		var me: Dictionary = await _request_json(normalized, "/api/me")
		if not bool(me.get("ok", false)):
			_bearer_token = ""
			return { "ok": false, "error": _response_error(me, "API token authentication failed.") }
		var user_data: Dictionary = {}
		var me_json = me.get("json", null)
		if typeof(me_json) == TYPE_DICTIONARY:
			var u = me_json.get("user", {})
			if typeof(u) == TYPE_DICTIONARY:
				user_data = u
		return { "ok": true, "user": user_data, "token": _bearer_token }

	# password mode
	var identifier := String(normalized.get("identifier", "")).strip_edges()
	if identifier.is_empty() or password.is_empty():
		return { "ok": false, "error": "Email/username and password are required." }
	var login: Dictionary = await _login_backend(normalized, identifier, password)
	if not bool(login.get("ok", false)):
		return login
	var me_resp: Dictionary = await _request_json(normalized, "/api/me")
	if not bool(me_resp.get("ok", false)):
		_bearer_token = ""
		_cookie_header = ""
		return { "ok": false, "error": _response_error(me_resp, "Login verification failed.") }
	var user: Dictionary = {}
	var me_json2 = me_resp.get("json", null)
	if typeof(me_json2) == TYPE_DICTIONARY:
		var uu = me_json2.get("user", {})
		if typeof(uu) == TYPE_DICTIONARY:
			user = uu
	return { "ok": true, "user": user, "token": _bearer_token }


## Fetches the user's accessible projects. Returns
## { "ok": true, "projects": [...], "shared": [...] } or { "ok": false, "error": ... }.
func fetch_projects(settings: Dictionary) -> Dictionary:
	var resp: Dictionary = await _request_json(settings, "/api/projects")
	if not bool(resp.get("ok", false)):
		return { "ok": false, "error": _response_error(resp, "Failed to fetch projects.") }
	var json = resp.get("json", {})
	if typeof(json) != TYPE_DICTIONARY:
		return { "ok": false, "error": "Invalid projects payload." }
	var own: Array = []
	var own_val = json.get("projects", [])
	if own_val is Array:
		own = own_val
	var shared: Array = []
	var shared_val = json.get("sharedProjects", [])
	if shared_val is Array:
		shared = shared_val
	return { "ok": true, "projects": own, "shared": shared }


## Returns the backend project ID matching the configured backend project name,
## or empty string if no match. Searches both owned and shared projects.
func find_project_id_by_name(projects_payload: Dictionary, project_name: String) -> String:
	var needle := String(project_name).strip_edges()
	if needle.is_empty():
		return ""
	var lists: Array = [
		projects_payload.get("projects", []),
		projects_payload.get("shared", []),
	]
	for list in lists:
		if typeof(list) != TYPE_ARRAY:
			continue
		for entry in list:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			if String(entry.get("name", "")).strip_edges() == needle:
				return String(entry.get("id", "")).strip_edges()
	return ""


## Generates a new API key via /api/auth/apikeys and saves it to settings.
## Caller must already be authenticated (Bearer token or session cookie).
func generate_api_token(settings: Dictionary) -> Dictionary:
	var normalized := normalize_settings(settings)
	var body := JSON.stringify({"name": "GodotWithU Auto Token"})
	var resp: Dictionary = await _request_json(normalized, "/api/auth/apikeys", HTTPClient.METHOD_POST, body)
	if not bool(resp.get("ok", false)):
		return { "ok": false, "error": _response_error(resp, "Token generation failed.") }
	var json = resp.get("json", {})
	if typeof(json) != TYPE_DICTIONARY:
		return { "ok": false, "error": "Bad response payload." }
	var key := String(json.get("key", "")).strip_edges()
	if key.is_empty():
		return { "ok": false, "error": "Server returned no key." }
	normalized["api_token"] = key
	normalized["auth_mode"] = AUTH_MODE_API_TOKEN
	save_settings(normalized)
	_bearer_token = key
	_cookie_header = ""
	return { "ok": true, "key": key, "settings": normalized }


## Fire-and-forget: POST an activity ping to /api/projects/ping so the React
## manager shows the local user as "online" while a GWU session is active.
## Pass disconnect=true to explicitly mark the user offline.
func post_activity_ping(project_name: String, open_files: Array, disconnect: bool = false, metadata: Dictionary = {}) -> void:
	if _bearer_token.is_empty() and _cookie_header.is_empty():
		return
	if project_name.is_empty():
		return
	var settings := load_settings()
	var body := { "project": project_name }
	for key in metadata.keys():
		body[key] = metadata[key]
	if open_files.size() > 0:
		body["open_files"] = open_files
	if disconnect:
		body["disconnect"] = true
	# Fire-and-forget — ignore the response.
	await _request_json(settings, "/api/projects/ping", HTTPClient.METHOD_POST, JSON.stringify(body))


## Blocking variant — safe to call from _exit_tree during Godot shutdown.
## Does not require the scene tree; uses raw HTTPClient with OS.delay_msec.
func post_activity_ping_blocking(project_name: String, disconnect: bool = false, metadata: Dictionary = {}) -> void:
	if _bearer_token.is_empty() and _cookie_header.is_empty():
		return
	if project_name.is_empty():
		return
	var settings := load_settings()
	var backend_url: String = _normalize_backend_url(String(settings.get("backend_url", DEFAULT_BACKEND_URL)))
	var url := backend_url + "/api/projects/ping"
	var body_dict: Dictionary = { "project": project_name }
	for key in metadata.keys():
		body_dict[key] = metadata[key]
	if disconnect:
		body_dict["disconnect"] = true
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])
	if not _bearer_token.is_empty():
		headers.append("Authorization: Bearer " + _bearer_token)
	elif not _cookie_header.is_empty():
		headers.append("Cookie: " + _cookie_header)
	_http_request_blocking(url, HTTPClient.METHOD_POST, headers, JSON.stringify(body_dict), 2.0)


func _http_request_blocking(url: String, method: int, headers: PackedStringArray, body: String, timeout_sec: float) -> void:
	var parsed := _parse_http_url(url)
	if parsed.is_empty():
		return
	var client := HTTPClient.new()
	var use_tls := String(parsed.get("scheme", "")) == "https"
	var err: int
	if use_tls:
		err = client.connect_to_host(String(parsed.get("host", "")), int(parsed.get("port", 443)), TLSOptions.client())
	else:
		err = client.connect_to_host(String(parsed.get("host", "")), int(parsed.get("port", 80)))
	if err != OK:
		return
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while client.get_status() == HTTPClient.STATUS_RESOLVING or client.get_status() == HTTPClient.STATUS_CONNECTING:
		client.poll()
		if Time.get_ticks_msec() >= deadline:
			client.close()
			return
		OS.delay_msec(10)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return
	if client.request(method, String(parsed.get("path", "/")), headers, body) != OK:
		client.close()
		return
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if Time.get_ticks_msec() >= deadline:
			client.close()
			return
		OS.delay_msec(10)
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		client.read_response_body_chunk()
		if Time.get_ticks_msec() >= deadline:
			break
		OS.delay_msec(10)
	client.close()


func _parse_http_url(url: String) -> Dictionary:
	var normalized := String(url).strip_edges()
	var scheme_end := normalized.find("://")
	if scheme_end <= 0:
		return {}
	var scheme := normalized.substr(0, scheme_end).to_lower()
	if scheme != "http" and scheme != "https":
		return {}
	var rest := normalized.substr(scheme_end + 3)
	var slash_index := rest.find("/")
	var authority := rest if slash_index == -1 else rest.substr(0, slash_index)
	var path_part: String = "/" if slash_index == -1 else rest.substr(slash_index)
	if authority.is_empty():
		return {}
	var host := authority
	var port := 443 if scheme == "https" else 80
	var colon_index := authority.rfind(":")
	if colon_index >= 0:
		host = authority.substr(0, colon_index)
		port = int(authority.substr(colon_index + 1))
	return { "scheme": scheme, "host": host, "port": port, "path": path_part }


## Fire-and-forget: POST a collab presence event to the backend so the
## React manager can surface a same-file notification to all project members.
func post_collab_presence(project_id: String, file_path: String, peer_name: String) -> void:
	if _bearer_token.is_empty() and _cookie_header.is_empty():
		return
	if project_id.is_empty() or file_path.is_empty():
		return
	var settings := load_settings()
	var body := JSON.stringify({
		"file_path": file_path,
		"peer_name": peer_name,
	})
	await _request_json(settings, "/api/projects/%s/collab/presence" % project_id, HTTPClient.METHOD_POST, body)


## Fire-and-forget: POST a disconnection event to the backend so all project
## members receive a live toast in the manager (type: collab_disconnected).
func post_disconnection_event(project_id: String, peer_name: String) -> void:
	if _bearer_token.is_empty() and _cookie_header.is_empty():
		return
	if project_id.is_empty():
		return
	var settings := load_settings()
	var body := JSON.stringify({
		"peer_name": peer_name,
	})
	await _request_json(settings, "/api/projects/%s/collab/disconnect" % project_id, HTTPClient.METHOD_POST, body)


func _login_backend(settings: Dictionary, identifier: String, password: String) -> Dictionary:
	var payload := JSON.stringify({
		"identifier": identifier,
		"password": password,
	})
	var headers := PackedStringArray([
		"Accept: application/json",
		"Content-Type: application/json",
	])
	var resp: Dictionary = await _perform_http_request(
		_build_endpoint_url(settings, "/api/auth/editor-login"),
		HTTPClient.METHOD_POST,
		headers,
		payload
	)
	if not bool(resp.get("ok", false)):
		_bearer_token = ""
		_cookie_header = ""
		return { "ok": false, "error": _response_error(resp, "Editor login failed.") }
	var response_headers: Dictionary = resp.get("headers", {})
	_bearer_token = String(response_headers.get("set-auth-token", "")).strip_edges()
	_cookie_header = _build_cookie_header(response_headers.get("set-cookie", PackedStringArray()))
	if _bearer_token.is_empty() and _cookie_header.is_empty():
		return { "ok": false, "error": "Login succeeded but no reusable session was returned." }
	return { "ok": true }


# ─── HTTP helpers ─────────────────────────────────────────

func _request_json(settings: Dictionary, endpoint_path: String, method: int = HTTPClient.METHOD_GET, request_body: String = "") -> Dictionary:
	var headers := PackedStringArray(["Accept: application/json"])
	if not request_body.is_empty():
		headers.append("Content-Type: application/json")
	for header in _build_auth_headers():
		headers.append(header)
	return await _perform_http_request(_build_endpoint_url(settings, endpoint_path), method, headers, request_body)


func _build_endpoint_url(settings: Dictionary, endpoint_path: String) -> String:
	var base_url := _normalize_backend_url(String(settings.get("backend_url", DEFAULT_BACKEND_URL)).strip_edges())
	var path_part := String(endpoint_path).strip_edges()
	if not path_part.begins_with("/"):
		path_part = "/" + path_part
	if OS.has_feature("web") and base_url == DEFAULT_BACKEND_URL:
		var web_origin := _get_web_origin()
		# Only route through the same-origin proxy in local dev, where the WASM
		# editor (e.g. localhost:8060) is a different origin than the backend.
		# On studio.godaas.org the editor and backend share the same origin, so
		# call the backend directly — the /api/godaas-proxy route does not exist
		# there and would 404.
		if not web_origin.is_empty() and _is_local_web_origin(web_origin):
			return web_origin + "/api/godaas-proxy" + path_part
	return base_url + path_part


func _get_web_origin() -> String:
	if not OS.has_feature("web"):
		return ""
	var origin = JavaScriptBridge.eval("window.location.origin", true)
	return String(origin).strip_edges()


## True when the web editor is served from localhost / 127.0.0.1 (local dev),
## where the same-origin /api/godaas-proxy is needed to reach the backend.
func _is_local_web_origin(web_origin: String) -> bool:
	var host := String(web_origin).strip_edges().to_lower()
	var scheme_end := host.find("://")
	if scheme_end != -1:
		host = host.substr(scheme_end + 3)
	var slash_index := host.find("/")
	if slash_index != -1:
		host = host.substr(0, slash_index)
	var colon_index := host.rfind(":")
	if colon_index != -1:
		host = host.substr(0, colon_index)
	return host == "localhost" or host == "127.0.0.1" or host == "::1" or host.ends_with(".localhost")


func _build_auth_headers() -> PackedStringArray:
	var headers := PackedStringArray()
	if not _bearer_token.is_empty():
		headers.append("Authorization: Bearer " + _bearer_token)
	elif not _cookie_header.is_empty():
		headers.append("Cookie: " + _cookie_header)
	return headers


func _perform_http_request(url: String, method: int, headers: PackedStringArray, request_body: String = "") -> Dictionary:
	if _http_parent == null:
		return { "ok": false, "error": "Auth client not attached." }
	var request := HTTPRequest.new()
	# In the web/WASM editor the browser's fetch already decompresses gzip
	# responses transparently. With accept_gzip on, HTTPRequest would then try to
	# gunzip the already-decompressed body (because the Content-Encoding: gzip
	# header is still present) and fail with RESULT_BODY_DECOMPRESS_FAILED (8) —
	# studio.godaas.org gzips JSON bodies >= 1KB (e.g. /api/projects, /api/me).
	if OS.has_feature("web"):
		request.accept_gzip = false
	_http_parent.add_child(request)
	var request_error := request.request(url, headers, method, request_body)
	if request_error != OK:
		request.queue_free()
		return {
			"ok": false,
			"status_code": 0,
			"headers": {},
			"body_text": "",
			"json": null,
			"error": "Request error %d." % request_error,
		}
	var completed: Array = await request.request_completed
	request.queue_free()
	var request_result := int(completed[0])
	var status_code := int(completed[1])
	var response_headers := _parse_http_headers(completed[2])
	var body_bytes: PackedByteArray = completed[3]
	var body_text := body_bytes.get_string_from_utf8()
	var json_body = _parse_json_response(body_text, response_headers)
	var ok := request_result == HTTPRequest.RESULT_SUCCESS and status_code >= 200 and status_code < 300
	var error_message := ""
	if request_result != HTTPRequest.RESULT_SUCCESS:
		error_message = "Request failed (%d)." % request_result
	elif not ok:
		error_message = _extract_error_message(json_body, status_code)
	elif json_body == null and not body_text.strip_edges().is_empty():
		ok = false
		error_message = "Backend returned a non-JSON response."
	return {
		"ok": ok,
		"status_code": status_code,
		"headers": response_headers,
		"body_text": body_text,
		"json": json_body,
		"error": error_message,
	}


func _parse_json_response(body_text: String, response_headers: Dictionary) -> Variant:
	var stripped := body_text.strip_edges()
	if stripped.is_empty():
		return null
	var content_type := String(response_headers.get("content-type", "")).to_lower()
	if content_type.find("json") == -1 and not stripped.begins_with("{") and not stripped.begins_with("["):
		return null
	var parser := JSON.new()
	if parser.parse(stripped) != OK:
		return null
	return parser.data


func _parse_http_headers(raw_headers: Array) -> Dictionary:
	var headers := {}
	var set_cookies := PackedStringArray()
	for header_line in raw_headers:
		var line := String(header_line)
		var separator_index := line.find(":")
		if separator_index == -1:
			continue
		var key := line.substr(0, separator_index).strip_edges().to_lower()
		var value := line.substr(separator_index + 1).strip_edges()
		if key == "set-cookie":
			set_cookies.append(value)
			continue
		headers[key] = value
	headers["set-cookie"] = set_cookies
	return headers


func _build_cookie_header(set_cookies: PackedStringArray) -> String:
	var cookie_parts := []
	for raw_cookie in set_cookies:
		var cookie_value := String(raw_cookie).split(";", false)[0].strip_edges()
		if not cookie_value.is_empty():
			cookie_parts.append(cookie_value)
	return "; ".join(cookie_parts)


func _extract_error_message(json_body: Variant, status_code: int) -> String:
	if typeof(json_body) == TYPE_DICTIONARY:
		var message := String(json_body.get("error", "")).strip_edges()
		if not message.is_empty():
			return message
	match status_code:
		401:
			return "Authentication failed. Check your token or credentials."
		403:
			return "Access denied."
		_:
			return "Request failed with HTTP %d." % status_code


func _response_error(response: Dictionary, fallback: String) -> String:
	var message := String(response.get("error", "")).strip_edges()
	return message if not message.is_empty() else fallback
