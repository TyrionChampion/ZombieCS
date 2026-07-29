@tool
extends RefCounted

const ALLOWED_METHODS: PackedStringArray = [
	"health.ping",
	"editor.get_info",
	"editor.get_selection",
	"editor.select_node",
	"editor.ui.get_layout_state",
	"editor.ui.focus_panel",
	"editor.selection.get_details",
	"editor.docks.layout.get",
	"editor.docks.layout.set",
	"editor.inspector.batch_edit",
	"editor.context.snapshot",
	"scene.list_open",
	"scene.open",
	"scene.new",
	"scene.save",
	"scene.save_as",
	"scene.close",
	"scene.close_all",
	"scene.get_tree",
	"scene.find_nodes",
	"scene.instantiate",
	"scene.instances.list",
	"scene.instances.replace",
	"scene.owners.repair",
	"scene.paths.normalize",
	"scene.dependencies.list",
	"animation.players.list",
	"animation.players.create",
	"animation.animations.list",
	"animation.animations.create",
	"animation.animations.remove",
	"animation.tracks.list",
	"animation.tracks.add",
	"animation.tracks.remove",
	"animation.keys.insert",
	"animation.keys.remove",
	"animation.keys.clear_range",
	"animation.length.set",
	"animation.loop.set",
	"animation.preview.play",
	"animation.preview.stop",
	"node.add",
	"node.remove",
	"node.duplicate",
	"node.reparent",
	"node.rename",
	"node.set_owner",
	"node.get_properties",
	"node.set_property",
	"node.batch_set_property",
	"node.signals.list",
	"node.signals.connect",
	"node.signals.disconnect",
	"node.groups.list",
	"node.groups.add",
	"node.groups.remove",
	"inspector.schema.get",
	"inspector.schema.get_filtered",
	"inspector.values.get",
	"inspector.values.patch",
	"inspector.values.patch_preview",
	"inspector.values.diff",
	"inspector.batch.apply",
	"inspector.preset.capture",
	"inspector.preset.apply",
	"node.call_method",
	"resource.load",
	"resource.save",
	"resource.create",
	"resource.dependencies.graph",
	"resource.references.find",
	"resource.replace_path",
	"resource.batch_replace_paths",
	"resource.orphans.find",
	"resource.duplicate",
	"resource.move",
	"resource.rename",
	"script.create",
	"script.attach",
	"script.get_text",
	"script.set_text",
	"script.ast.find_symbols",
	"script.refactor.rename_symbol",
	"script.refactor.add_method_stub",
	"script.refactor.organize_regions",
	"project.play",
	"project.stop",
	"project.reload",
	"project.get_main_scene",
	"project.set_main_scene",
	"project.inputmap.list",
	"project.inputmap.set",
	"project.inputmap.erase",
	"project.autoload.list",
	"project.autoload.add",
	"project.autoload.remove",
	"project.build",
	"diagnostics.get_errors",
	"diagnostics.get_warnings",
	"screenshot.capture_editor",
	"screenshot.capture_game",
	"runtime.logs.tail",
	"runtime.logs.stream",
	"runtime.logs.parse_errors",
	"runtime.debugger.snapshot",
	"runtime.errors.delta",
	"runtime.observe_after_play",
	"runtime.ping_game",
	"runtime.eval",
	"runtime.node.get_property",
	"runtime.node.call_method",
	"runtime.node.find",
	"runtime.behavior.check",
	"assets.images.search",
	"assets.images.preview",
	"filesystem.list_dir",
	"filesystem.read_text",
	"filesystem.read_text_batch",
	"filesystem.write_text",
	"filesystem.write_text_batch",
	"filesystem.search",
	"undo.begin_action",
	"undo.end_action",
	"undo.commit",
	"undo.rollback",
	"capabilities.get",
	"session.get_state",
	"session.auto_capture.get",
	"session.auto_capture.set",
	"intent.suggest_payload",
]

const GUARDED_METHODS: PackedStringArray = [
	"node.remove",
	"filesystem.write_text",
	"filesystem.write_text_batch",
	"script.set_text",
	"scene.instances.replace",
	"scene.owners.repair",
	"resource.batch_replace_paths",
	"resource.move",
	"resource.rename",
	"script.refactor.rename_symbol",
	"script.refactor.organize_regions",
	"inspector.batch.apply",
	"inspector.preset.apply",
	"editor.docks.layout.set",
	"editor.inspector.batch_edit",
	"undo.rollback",
	"project.build",
]

func is_allowed_method(method: String) -> bool:
	return ALLOWED_METHODS.has(method)

func is_guarded_method(method: String) -> bool:
	return GUARDED_METHODS.has(method)

func should_require_confirmation(method: String, params: Dictionary) -> bool:
	if bool(params.get("__confirmed", false)):
		return false
	if not is_guarded_method(method):
		return false
	if method == "node.remove":
		var node_path := str(params.get("node_path", ""))
		return node_path == "." or node_path == "" or node_path == "/root"
	if method == "filesystem.write_text":
		return bool(params.get("overwrite", false))
	if method == "filesystem.write_text_batch":
		var items = params.get("items", [])
		if typeof(items) != TYPE_ARRAY:
			return false
		for item in items:
			if typeof(item) == TYPE_DICTIONARY and bool(item.get("overwrite", false)):
				return true
		return false
	if method == "script.set_text":
		var content := str(params.get("content", ""))
		return content.length() > 3000
	if method == "scene.instances.replace":
		return not bool(params.get("dry_run", false))
	if method == "scene.owners.repair":
		return not bool(params.get("dry_run", false))
	if method == "resource.batch_replace_paths":
		return not bool(params.get("dry_run", false))
	if method == "resource.move":
		return not bool(params.get("dry_run", false))
	if method == "resource.rename":
		return not bool(params.get("dry_run", false))
	if method == "script.refactor.rename_symbol":
		return not bool(params.get("dry_run", false))
	if method == "script.refactor.organize_regions":
		return not bool(params.get("dry_run", false))
	if method == "inspector.batch.apply":
		return not bool(params.get("dry_run", false))
	if method == "inspector.preset.apply":
		return not bool(params.get("dry_run", false))
	if method == "editor.docks.layout.set":
		return not bool(params.get("dry_run", false))
	if method == "editor.inspector.batch_edit":
		return not bool(params.get("dry_run", false))
	if method == "undo.rollback":
		return true
	return true

func normalize_res_path(path: String) -> Dictionary:
	var p := path.strip_edges()
	if p == "":
		return {"ok": false, "error": "Path is empty"}

	if _looks_absolute_path(p):
		return {"ok": false, "error": "Absolute paths are not allowed"}

	if p.begins_with("res://"):
		if p.find("..") != -1:
			return {"ok": false, "error": "Path traversal is not allowed"}
		return {"ok": true, "path": p}

	if p.begins_with("./"):
		p = p.trim_prefix("./")

	if p.find("..") != -1:
		return {"ok": false, "error": "Path traversal is not allowed"}

	return {"ok": true, "path": "res://" + p.trim_prefix("/")}

func _looks_absolute_path(path: String) -> bool:
	if path.begins_with("/") or path.begins_with("\\"):
		return true
	if path.length() >= 2 and path[1] == ":":
		return true
	return false
