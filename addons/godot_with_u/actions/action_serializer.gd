@tool
# No global class_name: preloaded by path as ActionSerializerClass; declaring a
# global class breaks the source-reload fallback on re-enable ("hides a global script class").
extends RefCounted
## Serializes / deserializes editor action packets to/from PackedByteArray.
##
## Packet format uses Godot's native var_to_bytes (fast, supports all
## Variant types including Vector2/3, Transform2D/3D, NodePath, etc.).

const TAG := "ActionSerializer"
const RESOURCE_KIND_KEY := "__gwu_kind"
const RESOURCE_KIND_PATH := "resource_path"
const RESOURCE_KIND_SNAPSHOT := "resource_snapshot"
const RESOURCE_PATH_KEY := "resource_path"
const RESOURCE_TYPE_KEY := "resource_type"
const AUDIO_EXTENSIONS := [".ogg", ".wav", ".mp3"]
const SHADER_EXTENSIONS := [".gdshader", ".gdshaderinc"]
## Maximum number of inline-resource nesting levels to encode recursively.
## SpriteFrames → AtlasTexture → atlas image is depth 2; 4 is a safe ceiling.
const MAX_INLINE_DEPTH: int = 4


## Convert an action Dictionary → PackedByteArray for network transmission.
static func serialize(action: Dictionary) -> PackedByteArray:
	return var_to_bytes(action)


## Convert a PackedByteArray → action Dictionary.
## Returns an empty Dictionary on failure.
## Uses bytes_to_var (not bytes_to_var_with_objects) to prevent
## deserialization of arbitrary Object types from untrusted data.
static func deserialize(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var result = bytes_to_var(data)
	if result is Dictionary:
		return result
	push_warning("[%s] Deserialization did not yield a Dictionary." % TAG)
	return {}


## Convert property values to a network-safe representation.
## Most saved top-level resources are sent as paths so the receiver can load them.
## Mutable/editor-picked resources such as SpriteFrames, ShaderMaterial/Shader,
## and Animation data are sent as snapshots because their editor data changes
## under one resource object.
## Imported audio files (.ogg/.wav) should remain path-based ext_resource refs.
## Sub-resources embedded in a scene file (path contains '::') are sent with
## BOTH the path AND their inline properties.
## Truly inline (no path) resources are always serialized by value.
static func encode_property_value(value: Variant) -> Dictionary:
	if value == null:
		return {"ok": true, "value": null}

	if value is Script:
		return {"ok": false, "reason": "script resources sync via script_attach"}

	if value is Resource:
		var resource := value as Resource
		var resource_path := String(resource.resource_path)
		if not resource_path.is_empty():
			# Sub-resource embedded in a scene file: path contains '::'
			# Include inline properties as fallback in case the file is unsaved.
			if "::" in resource_path:
				return _encode_resource_snapshot(resource, "sub_resource", 0)
			if should_send_resource_snapshot(resource):
				return _encode_resource_snapshot(resource, RESOURCE_KIND_SNAPSHOT, 0)
			# Top-level saved resource: send path only
			return {
				"ok": true,
				"value": {
					RESOURCE_KIND_KEY: RESOURCE_KIND_PATH,
					RESOURCE_PATH_KEY: resource_path,
					RESOURCE_TYPE_KEY: resource.get_class(),
				},
			}
		# Inline sub-resource (no saved path) — encode storable properties
		return _encode_inline_resource(resource, 0)

	return {"ok": true, "value": value}


static func should_send_resource_snapshot(resource: Resource) -> bool:
	return resource is SpriteFrames \
		or resource is ShaderMaterial \
		or resource is Shader \
		or resource is AnimationLibrary \
		or resource is Animation


static func _encode_resource_snapshot(
		resource: Resource, kind: String, depth: int = 0) -> Dictionary:
	var inline := _encode_inline_resource(resource, depth)
	if not bool(inline.get("ok", false)):
		return inline
	var payload: Dictionary = inline.get("value", {})
	payload[RESOURCE_KIND_KEY] = kind
	var resource_path := String(resource.resource_path)
	if not resource_path.is_empty():
		payload[RESOURCE_PATH_KEY] = resource_path
	payload[RESOURCE_TYPE_KEY] = resource.get_class()
	return {"ok": true, "value": payload}


## Serialize an inline (unsaved) Resource by recording its PROPERTY_USAGE_STORAGE
## properties as plain Variant values. depth tracks how many inline-resource
## levels deep we are; recursion stops at MAX_INLINE_DEPTH.
static func _encode_inline_resource(resource: Resource, depth: int = 0) -> Dictionary:
	var type_name := resource.get_class()
	var props: Dictionary = {}
	for prop in resource.get_property_list():
		var pname: String = prop["name"]
		var pusage: int = prop["usage"]
		if pusage & PROPERTY_USAGE_STORAGE == 0:
			continue
		# resource_path is transmitted separately in RESOURCE_PATH_KEY.
		# script syncs via script_attach.
		# resource_name is cosmetic — excluding it avoids expensive re-serialization
		# of the whole resource on every keypress while the user edits the name field.
		# resource_local_to_scene is intentionally included.
		if pname in ["script", "resource_path", "resource_name"]:
			continue
		var pval: Variant = resource.get(pname)
		# Non-Resource Objects (e.g. raw Node refs) cannot be serialised — skip them.
		if pval is Object and not (pval is Resource):
			continue
		props[pname] = _encode_variant_deep(pval, depth)
	return {
		"ok": true,
		"value": {
			RESOURCE_KIND_KEY: "inline_resource",
			RESOURCE_TYPE_KEY: type_name,
			"properties": props,
		},
	}


## Recursively encode a Variant, replacing Resource values with path-based
## or inline-resource dictionaries so they survive var_to_bytes.
## depth counts inline-resource nesting levels; stops at MAX_INLINE_DEPTH.
## Bypasses encode_property_value intentionally so depth is threaded through.
static func _encode_variant_deep(val: Variant, depth: int = 0) -> Variant:
	if val is Script:
		return null  # scripts sync via script_attach
	if val is Resource:
		var resource := val as Resource
		var resource_path := String(resource.resource_path)
		if not resource_path.is_empty():
			if "::" in resource_path:
				# resource_local_to_scene sub-resource: encode path + inline fallback.
				# Inline fallback allows the receiver to reconstruct even if the
				# scene file is not yet saved/synced on their side.
				if depth < MAX_INLINE_DEPTH:
					var snapshot := _encode_resource_snapshot(resource, "sub_resource", depth + 1)
					if bool(snapshot.get("ok", false)):
						return snapshot.get("value")
			if should_send_resource_snapshot(resource) and depth < MAX_INLINE_DEPTH:
				var snapshot := _encode_resource_snapshot(resource, RESOURCE_KIND_SNAPSHOT, depth + 1)
				if bool(snapshot.get("ok", false)):
					return snapshot.get("value")
			# Top-level saved resource: path is sufficient.
			return {
				RESOURCE_KIND_KEY: RESOURCE_KIND_PATH,
				RESOURCE_PATH_KEY: resource_path,
				RESOURCE_TYPE_KEY: resource.get_class(),
			}
		# Truly inline resource (no path): encode properties if depth allows.
		if depth >= MAX_INLINE_DEPTH:
			return null
		var enc := _encode_inline_resource(resource, depth + 1)
		return enc.get("value") if enc.get("ok", false) else null
	if val is Object:
		return null  # non-Resource Object — drop it
	if val is Array:
		var out: Array = []
		for item in (val as Array):
			out.append(_encode_variant_deep(item, depth))
		return out
	if val is Dictionary:
		var out: Dictionary = {}
		for key in (val as Dictionary):
			out[key] = _encode_variant_deep((val as Dictionary)[key], depth)
		return out
	return val


## Reverse of _encode_variant_deep: restore encoded resource dicts back to
## Resource objects (or null on failure), and walk nested Arrays/Dicts.
static func _decode_variant_deep(val: Variant) -> Variant:
	if val is Dictionary:
		var d := val as Dictionary
		if d.has(RESOURCE_KIND_KEY):
			var dec: Dictionary = decode_property_value(d)
			return dec.get("value") if dec.get("ok", false) else null
		var out: Dictionary = {}
		for key in d:
			out[key] = _decode_variant_deep(d[key])
		return out
	if val is Array:
		var out: Array = []
		for item in (val as Array):
			out.append(_decode_variant_deep(item))
		return out
	return val


## Decode a network-safe property payload back into the local value.
static func decode_property_value(value: Variant) -> Dictionary:
	if not (value is Dictionary) or not (value as Dictionary).has(RESOURCE_KIND_KEY):
		return {"ok": true, "value": value}

	var payload: Dictionary = value
	var kind := String(payload.get(RESOURCE_KIND_KEY, ""))

	if kind == RESOURCE_KIND_PATH:
		var resource_path := String(payload.get(RESOURCE_PATH_KEY, ""))
		var resource_type := String(payload.get(RESOURCE_TYPE_KEY, ""))
		if resource_path.is_empty():
			push_warning("[%s] Refused to decode resource property with empty path." % TAG)
			return {"ok": false, "reason": "resource path is empty"}
		var resource := _load_resource_path(resource_path, resource_type)
		if not resource:
			return {
				"ok": false,
				"reason": "resource load failed",
				"resource_path": resource_path,
				"resource_type": resource_type,
			}
		return {"ok": true, "value": resource}

	if kind == "sub_resource":
		var resource_path := String(payload.get(RESOURCE_PATH_KEY, ""))
		var resource_type := String(payload.get(RESOURCE_TYPE_KEY, ""))
		var props: Dictionary = payload.get("properties", {})
		if not props.is_empty():
			return _decode_inline_resource(payload)
		# Only attempt a disk load when the path is actually present in the project.
		# Sub-resource paths (containing '::') won't exist on a peer that hasn't
		# saved/synced the scene file yet — skip straight to inline reconstruction
		# to avoid ResourceLoader error spam in that common case.
		if not resource_path.is_empty() and ResourceLoader.exists(resource_path):
			var res := ResourceLoader.load(resource_path, resource_type, ResourceLoader.CACHE_MODE_REUSE)
			if res:
				return {"ok": true, "value": res}
		# Path absent or load failed — reconstruct from inline properties
		return _decode_inline_resource(payload)

	if kind == RESOURCE_KIND_SNAPSHOT:
		return _decode_inline_resource(payload)

	if kind == "inline_resource":
		return _decode_inline_resource(payload)

	return {"ok": false, "reason": "unknown resource encoding: " + kind}


static func _load_resource_path(resource_path: String, resource_type: String) -> Resource:
	var candidates: Array[String] = []
	if not resource_type.is_empty():
		candidates.append(resource_type)
	if _is_audio_path(resource_path):
		candidates.append("AudioStream")
	if _is_shader_path(resource_path):
		candidates.append("Shader")
	candidates.append("")

	for candidate in candidates:
		var res := ResourceLoader.load(resource_path, candidate, ResourceLoader.CACHE_MODE_REUSE)
		if res:
			return res

	if FileAccess.file_exists(resource_path):
		if Engine.is_editor_hint():
			var fs := EditorInterface.get_resource_filesystem()
			if fs:
				fs.update_file(resource_path)
		for candidate in candidates:
			var res := ResourceLoader.load(resource_path, candidate, ResourceLoader.CACHE_MODE_REPLACE)
			if res:
				return res

	return null


static func _is_audio_path(resource_path: String) -> bool:
	var lower_path := resource_path.to_lower()
	for extension in AUDIO_EXTENSIONS:
		if lower_path.ends_with(extension):
			return true
	return false


static func _is_shader_path(resource_path: String) -> bool:
	var lower_path := resource_path.to_lower()
	for extension in SHADER_EXTENSIONS:
		if lower_path.ends_with(extension):
			return true
	return false


## Reconstruct a Resource from encoded inline properties.
static func _decode_inline_resource(payload: Dictionary) -> Dictionary:
	var type_name := String(payload.get(RESOURCE_TYPE_KEY, ""))
	if type_name.is_empty() or not ClassDB.class_exists(StringName(type_name)):
		push_warning("[%s] Unknown inline resource type: '%s'" % [TAG, type_name])
		return {"ok": false, "reason": "unknown resource type"}
	# Security: only instantiate known Resource subclasses
	if not ClassDB.is_parent_class(StringName(type_name), StringName("Resource")):
		push_warning("[%s] Refused to instantiate non-Resource type: '%s'" % [TAG, type_name])
		return {"ok": false, "reason": "not a Resource subclass"}
	var rp := String(payload.get(RESOURCE_PATH_KEY, ""))
	var resource: Resource = null
	if not rp.is_empty() and FileAccess.file_exists(rp):
		resource = _load_resource_path(rp, type_name)
	if resource == null:
		var obj = ClassDB.instantiate(StringName(type_name))
		if not (obj is Resource):
			push_warning("[%s] Instantiation failed for inline resource: '%s'" % [TAG, type_name])
			return {"ok": false, "reason": "instantiation failed"}
		resource = obj as Resource
	var props: Dictionary = payload.get("properties", {})
	for pname: String in props:
		# resource_path is part of the payload dict (RESOURCE_PATH_KEY), not inline props.
		# script syncs separately. All other fields including resource_local_to_scene
		# and resource_name are restored directly.
		if pname in ["script", "resource_path"]:
			continue
		resource.set(pname, _decode_variant_deep(props[pname]))
	resource.emit_changed()
	# Restore the resource path so it shows correctly in the Inspector and
	# future ResourceLoader.load() calls return this instance from cache.
	if not rp.is_empty():
		resource.take_over_path(rp)
		if resource is Shader and String(resource.resource_name).is_empty():
			resource.resource_name = rp.get_file().get_basename()
	return {"ok": true, "value": resource}
