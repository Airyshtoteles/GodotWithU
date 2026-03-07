@tool
class_name ActionSerializer
extends RefCounted
## Serializes / deserializes editor action packets to/from PackedByteArray.
##
## Packet format uses Godot's native var_to_bytes (fast, supports all
## Variant types including Vector2/3, Transform2D/3D, NodePath, etc.).

const TAG := "ActionSerializer"


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
