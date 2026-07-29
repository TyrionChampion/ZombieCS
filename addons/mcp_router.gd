@tool
extends RefCounted

const ERR_SCENE_CONTEXT := -32010
const ERR_PATH_VIOLATION := -32020
const ERR_GUARDED_ACTION := -32030
const ERR_EDITOR_BUSY := -32040
const RPC_PARSE_ERROR := -32700
const RPC_INVALID_REQUEST := -32600
const RPC_METHOD_NOT_FOUND := -32601
const RPC_INVALID_PARAMS := -32602
const RUNTIME_POLL_INTERVAL_MS := 10
const RUNTIME_DEFAULT_TIMEOUT_MS := 3000

var _plugin: EditorPlugin
var _guard
var _state
var _undo_action_open := false
var _undo_action_name := ""
var _undo_scene_snapshot_path := ""
var _undo_scene_original_path := ""
var _undo_file_snapshots: Dictionary = {}
var _undo_started_at_unix := 0
var _undo_snapshot_counter := 0
var _undo_replaying := false
var _undo_change_count := 0
var _debugger_plugin = null

func _init(plugin: EditorPlugin, guard, state) -> void:
	_plugin = plugin
	_guard = guard
	_state = state

func set_debugger_plugin(plugin) -> void:
	_debugger_plugin = plugin

func handle_jsonrpc(req: Variant) -> Variant:
	if typeof(req) != TYPE_DICTIONARY:
		return _rpc_error(null, RPC_PARSE_ERROR, "Invalid request payload")

	var id = req.get("id", null)
	var method = str(req.get("method", ""))
	var params = req.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	if method == "":
		return _rpc_error(id, RPC_INVALID_REQUEST, "Missing method")

	if not _guard.is_allowed_method(method):
		return _rpc_error(id, RPC_METHOD_NOT_FOUND, "Method not allowed: %s" % method)

	if _guard.should_require_confirmation(method, params):
		return _rpc_error(id, ERR_GUARDED_ACTION, "Action requires confirmation token")

	_state.set_last_method(method)
	var routed = _dispatch(method, params)
	if routed.get("ok", false):
		return _rpc_ok(id, routed.get("data", {}))

	var code = int(routed.get("code", -32000))
	var message = str(routed.get("message", "Unknown error"))
	var data = routed.get("data", {})
	_state.record_error(message, {"code": code, "method": method, "data": data})
	return _rpc_error(id, code, message, data)

func _dispatch(method: String, params: Dictionary) -> Dictionary:
	match method:
		"health.ping":
			return _ok({"status": "pong", "timestamp": Time.get_datetime_string_from_system()})
		"editor.get_info":
			return _editor_get_info()
		"editor.get_selection":
			return _editor_get_selection()
		"editor.select_node":
			return _editor_select_node(params)
		"editor.ui.get_layout_state":
			return _editor_ui_get_layout_state()
		"editor.ui.focus_panel":
			return _editor_ui_focus_panel(params)
		"editor.selection.get_details":
			return _editor_selection_get_details()
		"editor.docks.layout.get":
			return _editor_docks_layout_get()
		"editor.docks.layout.set":
			return _editor_docks_layout_set(params)
		"editor.inspector.batch_edit":
			return _editor_inspector_batch_edit(params)
		"editor.context.snapshot":
			return _editor_context_snapshot(params)
		"scene.list_open":
			return _scene_list_open()
		"scene.open":
			return _scene_open(params)
		"scene.new":
			return _scene_new()
		"scene.save":
			return _scene_save(params)
		"scene.save_as":
			return _scene_save_as(params)
		"scene.close":
			return _scene_close()
		"scene.close_all":
			return _scene_close_all()
		"scene.get_tree":
			return _scene_get_tree()
		"scene.find_nodes":
			return _scene_find_nodes(params)
		"scene.instantiate":
			return _scene_instantiate(params)
		"scene.instances.list":
			return _scene_instances_list(params)
		"scene.instances.replace":
			return _scene_instances_replace(params)
		"scene.owners.repair":
			return _scene_owners_repair(params)
		"scene.paths.normalize":
			return _scene_paths_normalize(params)
		"scene.dependencies.list":
			return _scene_dependencies_list(params)
		"animation.players.list":
			return _animation_players_list(params)
		"animation.players.create":
			return _animation_players_create(params)
		"animation.animations.list":
			return _animation_animations_list(params)
		"animation.animations.create":
			return _animation_animations_create(params)
		"animation.animations.remove":
			return _animation_animations_remove(params)
		"animation.tracks.list":
			return _animation_tracks_list(params)
		"animation.tracks.add":
			return _animation_tracks_add(params)
		"animation.tracks.remove":
			return _animation_tracks_remove(params)
		"animation.keys.insert":
			return _animation_keys_insert(params)
		"animation.keys.remove":
			return _animation_keys_remove(params)
		"animation.keys.clear_range":
			return _animation_keys_clear_range(params)
		"animation.length.set":
			return _animation_length_set(params)
		"animation.loop.set":
			return _animation_loop_set(params)
		"animation.preview.play":
			return _animation_preview_play(params)
		"animation.preview.stop":
			return _animation_preview_stop(params)
		"node.add":
			return _node_add(params)
		"node.remove":
			return _node_remove(params)
		"node.duplicate":
			return _node_duplicate(params)
		"node.reparent":
			return _node_reparent(params)
		"node.rename":
			return _node_rename(params)
		"node.set_owner":
			return _node_set_owner(params)
		"node.get_properties":
			return _node_get_properties(params)
		"node.set_property":
			return _node_set_property(params)
		"node.batch_set_property":
			return _node_batch_set_property(params)
		"node.signals.list":
			return _node_signals_list(params)
		"node.signals.connect":
			return _node_signals_connect(params)
		"node.signals.disconnect":
			return _node_signals_disconnect(params)
		"node.groups.list":
			return _node_groups_list(params)
		"node.groups.add":
			return _node_groups_add(params)
		"node.groups.remove":
			return _node_groups_remove(params)
		"inspector.schema.get":
			return _inspector_schema_get(params)
		"inspector.schema.get_filtered":
			return _inspector_schema_get_filtered(params)
		"inspector.values.get":
			return _inspector_values_get(params)
		"inspector.values.patch":
			return _inspector_values_patch(params)
		"inspector.values.patch_preview":
			return _inspector_values_patch_preview(params)
		"inspector.values.diff":
			return _inspector_values_diff(params)
		"inspector.batch.apply":
			return _inspector_batch_apply(params)
		"inspector.preset.capture":
			return _inspector_preset_capture(params)
		"inspector.preset.apply":
			return _inspector_preset_apply(params)
		"node.call_method":
			return _node_call_method(params)
		"resource.load":
			return _resource_load(params)
		"resource.save":
			return _resource_save(params)
		"resource.create":
			return _resource_create(params)
		"resource.dependencies.graph":
			return _resource_dependencies_graph(params)
		"resource.references.find":
			return _resource_references_find(params)
		"resource.replace_path":
			return _resource_replace_path(params)
		"resource.batch_replace_paths":
			return _resource_batch_replace_paths(params)
		"resource.orphans.find":
			return _resource_orphans_find(params)
		"resource.duplicate":
			return _resource_duplicate(params)
		"resource.move":
			return _resource_move(params)
		"resource.rename":
			return _resource_rename(params)
		"script.create":
			return _script_create(params)
		"script.attach":
			return _script_attach(params)
		"script.get_text":
			return _script_get_text(params)
		"script.set_text":
			return _script_set_text(params)
		"script.ast.find_symbols":
			return _script_ast_find_symbols(params)
		"script.refactor.rename_symbol":
			return _script_refactor_rename_symbol(params)
		"script.refactor.add_method_stub":
			return _script_refactor_add_method_stub(params)
		"script.refactor.organize_regions":
			return _script_refactor_organize_regions(params)
		"project.play":
			return _project_play()
		"project.stop":
			return _project_stop()
		"project.reload":
			return _project_reload()
		"project.get_main_scene":
			return _project_get_main_scene()
		"project.set_main_scene":
			return _project_set_main_scene(params)
		"project.inputmap.list":
			return _project_inputmap_list(params)
		"project.inputmap.set":
			return _project_inputmap_set(params)
		"project.inputmap.erase":
			return _project_inputmap_erase(params)
		"project.autoload.list":
			return _project_autoload_list()
		"project.autoload.add":
			return _project_autoload_add(params)
		"project.autoload.remove":
			return _project_autoload_remove(params)
		"project.build":
			return _project_build(params)
		"diagnostics.get_errors":
			return _diagnostics_get_errors(params)
		"diagnostics.get_warnings":
			return _diagnostics_get_warnings(params)
		"screenshot.capture_editor":
			return _screenshot_capture_editor(params)
		"screenshot.capture_game":
			return _screenshot_capture_game(params)
		"runtime.logs.tail":
			return _runtime_logs_tail(params)
		"runtime.logs.stream":
			return _runtime_logs_stream(params)
		"runtime.logs.parse_errors":
			return _runtime_logs_parse_errors(params)
		"runtime.debugger.snapshot":
			return _runtime_debugger_snapshot(params)
		"runtime.errors.delta":
			return _runtime_errors_delta(params)
		"runtime.observe_after_play":
			return _runtime_observe_after_play(params)
		"runtime.ping_game":
			return _runtime_ping_game(params)
		"runtime.eval":
			return _runtime_eval_in_game(params)
		"runtime.node.get_property":
			return _runtime_node_get_property(params)
		"runtime.node.call_method":
			return _runtime_node_call_method(params)
		"runtime.node.find":
			return _runtime_node_find(params)
		"runtime.behavior.check":
			return _runtime_behavior_check(params)
		"assets.images.search":
			return _assets_images_search(params)
		"assets.images.preview":
			return _assets_images_preview(params)
		"filesystem.list_dir":
			return _filesystem_list_dir(params)
		"filesystem.read_text":
			return _filesystem_read_text(params)
		"filesystem.read_text_batch":
			return _filesystem_read_text_batch(params)
		"filesystem.write_text":
			return _filesystem_write_text(params)
		"filesystem.write_text_batch":
			return _filesystem_write_text_batch(params)
		"filesystem.search":
			return _filesystem_search(params)
		"undo.begin_action":
			return _undo_begin_action(params)
		"undo.end_action":
			return _undo_end_action()
		"undo.commit":
			return _undo_commit()
		"undo.rollback":
			return _undo_rollback()
		"capabilities.get":
			return _capabilities_get()
		"session.get_state":
			return _session_get_state()
		"session.auto_capture.get":
			return _session_auto_capture_get()
		"session.auto_capture.set":
			return _session_auto_capture_set(params)
		"intent.suggest_payload":
			return _intent_suggest_payload(params)
		_:
			return _err(RPC_METHOD_NOT_FOUND, "Unknown method")

func _editor_get_info() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	var version_info: Dictionary = Engine.get_version_info()
	var root = iface.get_edited_scene_root()
	return _ok({
		"godot_version": str(version_info.get("string", "unknown")),
		"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
		"project_path": ProjectSettings.globalize_path("res://"),
		"edited_scene_path": "" if root == null else str(root.scene_file_path),
	})

func _editor_get_selection() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	var selection = iface.get_selection()
	var selected: Array[String] = []
	for node in selection.get_selected_nodes():
		selected.append(str(node.get_path()))
	return _ok({"selected_nodes": selected})

func _editor_select_node(params: Dictionary) -> Dictionary:
	var node_path = str(params.get("node_path", ""))
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, node_path)
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found: %s" % node_path)
	var selection = _plugin.get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(node)
	return _ok({"selected_node": str(node.get_path())})

func _editor_ui_get_layout_state() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface == null:
		return _err(ERR_EDITOR_BUSY, "Editor interface is not available")
	var root = _current_root()
	var selection = iface.get_selection()
	var selected_paths: Array[String] = []
	for node in selection.get_selected_nodes():
		if node is Node:
			selected_paths.append(str(node.get_path()))
	var base_control = iface.get_base_control()
	var focus_owner = null
	if base_control != null and base_control.get_viewport() != null:
		focus_owner = base_control.get_viewport().gui_get_focus_owner()
	var focus_owner_name = ""
	var focus_owner_class = ""
	if focus_owner != null and focus_owner is Control:
		focus_owner_name = str(focus_owner.name)
		focus_owner_class = str(focus_owner.get_class())
	var active_panel = _detect_active_panel_from_focus(focus_owner_name, focus_owner_class)
	return _ok(
		{
			"edited_scene_root_path": "" if root == null else str(root.get_path()),
			"edited_scene_file_path": "" if root == null else str(root.scene_file_path),
			"selected_nodes": selected_paths,
			"selected_count": selected_paths.size(),
			"active_panel": active_panel,
			"focus_owner_name": focus_owner_name,
			"focus_owner_class": focus_owner_class,
			"available_panels": ["scene_tree", "inspector", "filesystem", "output"],
		}
	)

func _editor_ui_focus_panel(params: Dictionary) -> Dictionary:
	var panel = str(params.get("panel", "")).strip_edges().to_lower()
	if panel == "":
		return _err(RPC_INVALID_PARAMS, "Missing panel")
	var allowed = ["scene_tree", "inspector", "filesystem", "output"]
	if not allowed.has(panel):
		return _err(RPC_INVALID_PARAMS, "Unsupported panel: %s" % panel, {"allowed_panels": allowed})

	var iface = _plugin.get_editor_interface()
	if iface == null:
		return _err(ERR_EDITOR_BUSY, "Editor interface is not available")
	var base_control = iface.get_base_control()
	if base_control == null:
		return _err(ERR_EDITOR_BUSY, "Editor base control is not available")
	var control = _find_panel_control(base_control, panel)
	if control == null:
		return _err(ERR_EDITOR_BUSY, "Unable to focus requested panel in this editor layout", {"panel": panel})
	control.grab_focus()
	return _ok({"panel": panel, "focused": true, "control_name": str(control.name), "control_class": str(control.get_class())})

func _editor_selection_get_details() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface == null:
		return _err(ERR_EDITOR_BUSY, "Editor interface is not available")
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var selection = iface.get_selection()
	var items: Array[Dictionary] = []
	for node in selection.get_selected_nodes():
		if node is Node:
			items.append(_serialize_selection_node_details(node, root))
	return _ok({"selected_count": items.size(), "items": items})

func _editor_docks_layout_get() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface == null:
		return _err(ERR_EDITOR_BUSY, "Editor interface is not available")
	var base_control = iface.get_base_control()
	if base_control == null:
		return _err(ERR_EDITOR_BUSY, "Editor base control is not available")
	var ui_state = _editor_ui_get_layout_state()
	if not ui_state.get("ok", false):
		return ui_state
	var data = ui_state.get("data", {}).duplicate(true)
	data["layout_version"] = 1
	data["layout"] = _collect_editor_dock_layout(base_control)
	return _ok(data)

func _editor_docks_layout_set(params: Dictionary) -> Dictionary:
	var raw_layout = params.get("layout", {})
	if typeof(raw_layout) != TYPE_DICTIONARY:
		return _err(RPC_INVALID_PARAMS, "layout must be a dictionary")
	var strict = bool(params.get("strict", false))
	var dry_run = bool(params.get("dry_run", true))
	var errors: Array[Dictionary] = []
	var warnings: Array[String] = []
	var applied_count := 0
	var skipped_count := 0

	var requested_panel = str(raw_layout.get("active_panel", params.get("active_panel", ""))).strip_edges().to_lower()
	if requested_panel != "":
		if dry_run:
			applied_count += 1
		else:
			var focus_result = _editor_ui_focus_panel({"panel": requested_panel})
			if focus_result.get("ok", false):
				applied_count += 1
			else:
				errors.append(
					{
						"target": "active_panel",
						"panel": requested_panel,
						"reason": str(focus_result.get("message", "Failed to focus panel")),
						"code": int(focus_result.get("code", ERR_EDITOR_BUSY)),
					}
				)
	else:
		warnings.append("Layout payload does not contain active_panel")

	var raw_panels = raw_layout.get("panels", [])
	if typeof(raw_panels) == TYPE_ARRAY and raw_panels.size() > 0:
		skipped_count += raw_panels.size()
		warnings.append("Panel visibility/tab placement restore is not supported yet; skipped.")
	var raw_split_ratios = raw_layout.get("split_ratios", [])
	if typeof(raw_split_ratios) == TYPE_ARRAY and raw_split_ratios.size() > 0:
		skipped_count += raw_split_ratios.size()
		warnings.append("Split ratio restore is not supported yet; skipped.")
	var raw_dock_slots = raw_layout.get("dock_slots", [])
	if typeof(raw_dock_slots) == TYPE_ARRAY and raw_dock_slots.size() > 0:
		skipped_count += raw_dock_slots.size()
		warnings.append("Dock slot/tab restore is not supported yet; skipped.")

	var payload = {
		"applied": errors.is_empty(),
		"dry_run": dry_run,
		"strict": strict,
		"applied_count": applied_count,
		"skipped_count": skipped_count,
		"error_count": errors.size(),
		"errors": errors,
		"warnings": warnings,
	}
	if not dry_run and strict and not errors.is_empty():
		return _err(ERR_EDITOR_BUSY, "Strict layout apply failed", payload)
	return _ok(payload)

func _editor_inspector_batch_edit(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var raw_node_paths = params.get("node_paths", [])
	if typeof(raw_node_paths) != TYPE_ARRAY or raw_node_paths.is_empty():
		return _err(RPC_INVALID_PARAMS, "node_paths must be a non-empty array")
	if raw_node_paths.size() > 500:
		return _err(RPC_INVALID_PARAMS, "node_paths cannot exceed 500 items")
	var raw_patches = params.get("patches", [])
	if typeof(raw_patches) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "patches must be an array")

	var atomic = bool(params.get("atomic", true))
	var validate_only = bool(params.get("validate_only", false))
	var dry_run = bool(params.get("dry_run", true))
	var include_before_after = bool(params.get("include_before_after", false))
	var effective_dry_run = dry_run or validate_only

	var items: Array[Dictionary] = []
	var processed_count := 0
	var changed_count := 0
	var validation_failed = false
	var valid_patches := 0
	var invalid_patches := 0
	var type_mismatch_count := 0

	for raw_path in raw_node_paths:
		processed_count += 1
		var node_path = str(raw_path)
		var node = _resolve_node(root, node_path)
		if node == null:
			validation_failed = true
			items.append(
				{
					"node_path": node_path,
					"ok": false,
					"changed": false,
					"applied_count": 0,
					"applied": [],
					"error_count": 1,
					"errors": [{"error": "Node not found"}],
				}
			)
			continue

		var preview = _inspector_preview_node_patches(node, raw_patches)
		var node_errors = preview.get("errors", [])
		var node_error_count = int(preview.get("error_count", 0))
		var node_would_change_count = int(preview.get("would_change_count", 0))
		valid_patches += int(preview.get("valid_count", 0))
		invalid_patches += int(preview.get("invalid_count", 0))
		type_mismatch_count += int(preview.get("type_mismatch_count", 0))
		if node_error_count > 0:
			validation_failed = true

		var node_item = {
			"node_path": str(node.get_path()),
			"ok": node_error_count == 0 or not atomic,
			"changed": false,
			"applied_count": 0,
			"applied": [],
			"error_count": node_error_count,
			"errors": node_errors,
		}
		if effective_dry_run:
			node_item["changed"] = node_would_change_count > 0
			node_item["would_change_count"] = node_would_change_count
			if include_before_after:
				var preview_applied: Array[Dictionary] = []
				var preview_items = preview.get("items", [])
				if typeof(preview_items) == TYPE_ARRAY:
					for patch_preview in preview_items:
						if typeof(patch_preview) != TYPE_DICTIONARY:
							continue
						if not bool(patch_preview.get("ok", false)):
							continue
						if not bool(patch_preview.get("would_change", false)):
							continue
						preview_applied.append(
							{
								"path": str(patch_preview.get("path", "")),
								"before": patch_preview.get("current", null),
								"after": patch_preview.get("next", null),
							}
						)
				node_item["applied"] = preview_applied
				node_item["applied_count"] = preview_applied.size()
			if node_would_change_count > 0:
				changed_count += 1
			items.append(node_item)
			continue

		if atomic and node_error_count > 0:
			items.append(node_item)
			continue

		var old_values: Dictionary = {}
		var applied_items: Array[Dictionary] = []
		var node_applied_count := 0
		var preview_items_apply = preview.get("items", [])
		if typeof(preview_items_apply) == TYPE_ARRAY:
			for patch_preview in preview_items_apply:
				if typeof(patch_preview) != TYPE_DICTIONARY:
					continue
				if not bool(patch_preview.get("ok", false)):
					continue
				if not bool(patch_preview.get("would_change", false)):
					continue
				var property_name = str(patch_preview.get("path", ""))
				old_values[property_name] = node.get(property_name)
				node.set(property_name, _decode_value(patch_preview.get("next", null)))
				node_applied_count += 1
				if include_before_after:
					applied_items.append(
						{
							"path": property_name,
							"before": patch_preview.get("current", null),
							"after": patch_preview.get("next", null),
						}
					)
				else:
					applied_items.append({"path": property_name})
		if node_applied_count > 0:
			changed_count += 1
			_undo_register_node_properties(str(node.get_path()), old_values)
		node_item["changed"] = node_applied_count > 0
		node_item["applied_count"] = node_applied_count
		node_item["applied"] = applied_items
		items.append(node_item)

	var payload = {
		"target_count": raw_node_paths.size(),
		"processed_count": processed_count,
		"changed_count": changed_count,
		"dry_run": effective_dry_run,
		"validate_only": validate_only,
		"atomic": atomic,
		"ok": not (validation_failed and atomic and not effective_dry_run),
		"items": items,
		"summary": {
			"valid_patches": valid_patches,
			"invalid_patches": invalid_patches,
			"type_mismatch_count": type_mismatch_count,
		},
	}
	if not effective_dry_run and atomic and validation_failed:
		return _err(RPC_INVALID_PARAMS, "Batch edit validation failed", payload)
	return _ok(payload)

func _editor_context_snapshot(params: Dictionary) -> Dictionary:
	var include_layout = bool(params.get("include_layout", true))
	var include_inspector_schema = bool(params.get("include_inspector_schema", false))
	var include_recent_diagnostics = bool(params.get("include_recent_diagnostics", true))
	var diagnostics_limit = clamp(int(params.get("diagnostics_limit", 50)), 1, 200)

	var editor_info = _editor_get_info()
	if not editor_info.get("ok", false):
		return editor_info
	var ui_state = _editor_ui_get_layout_state()
	if not ui_state.get("ok", false):
		return ui_state
	var scene_list = _scene_list_open()
	var session_state = _session_get_state()
	if not session_state.get("ok", false):
		return session_state

	var selection_items: Array[Dictionary] = []
	var selected_paths: Array[String] = []
	var root = _current_root()
	if root != null:
		var selection_result = _editor_selection_get_details()
		if selection_result.get("ok", false):
			var raw_items = selection_result.get("data", {}).get("items", [])
			if typeof(raw_items) == TYPE_ARRAY:
				for item in raw_items:
					if typeof(item) != TYPE_DICTIONARY:
						continue
					selection_items.append(item)
					selected_paths.append(str(item.get("path", "")))

	var ui_data = ui_state.get("data", {})
	var session_data = session_state.get("data", {})
	var snapshot = {
		"timestamp": Time.get_datetime_string_from_system(),
		"editor_info": editor_info.get("data", {}),
		"scene_context": {
			"edited_scene_file_path": str(ui_data.get("edited_scene_file_path", "")),
			"edited_scene_root_path": str(ui_data.get("edited_scene_root_path", "")),
			"open_scenes": scene_list.get("data", {}).get("scenes", []),
		},
		"selection": {
			"count": selection_items.size(),
			"paths": selected_paths,
			"nodes": selection_items,
		},
		"ui": {
			"active_panel": str(ui_data.get("active_panel", "unknown")),
			"focus_owner_name": str(ui_data.get("focus_owner_name", "")),
			"focus_owner_class": str(ui_data.get("focus_owner_class", "")),
			"available_panels": ui_data.get("available_panels", []),
		},
		"undo": {
			"action_open": bool(session_data.get("undo_action_open", false)),
			"action_name": str(session_data.get("undo_action_name", "")),
			"change_count": int(session_data.get("undo_change_count", 0)),
		},
		"session": {
			"auto_capture": session_data.get("auto_capture", {}),
			"last_method": str(session_data.get("last_method", "")),
			"uptime_seconds": int(session_data.get("uptime_seconds", 0)),
		},
	}

	if include_recent_diagnostics:
		var errors = _diagnostics_get_errors({"limit": diagnostics_limit})
		var warnings = _diagnostics_get_warnings({"limit": diagnostics_limit})
		snapshot["diagnostics"] = {
			"errors": errors.get("data", {}).get("items", []),
			"warnings": warnings.get("data", {}).get("items", []),
		}
	if include_layout:
		var layout_result = _editor_docks_layout_get()
		if layout_result.get("ok", false):
			snapshot["layout_version"] = int(layout_result.get("data", {}).get("layout_version", 1))
			snapshot["layout"] = layout_result.get("data", {}).get("layout", {})
		else:
			snapshot["layout_error"] = {
				"code": int(layout_result.get("code", ERR_EDITOR_BUSY)),
				"reason": str(layout_result.get("message", "Failed to collect layout")),
			}
	if include_inspector_schema and selection_items.size() > 0:
		var first_path = str(selection_items[0].get("path", ""))
		if first_path != "":
			var schema = _inspector_schema_get({"node_path": first_path, "include_private": false})
			if schema.get("ok", false):
				snapshot["inspector_schema"] = schema.get("data", {})
			else:
				snapshot["inspector_schema_error"] = {
					"code": int(schema.get("code", RPC_INVALID_PARAMS)),
					"reason": str(schema.get("message", "Failed to collect inspector schema")),
				}
	return _ok(snapshot)

func _scene_list_open() -> Dictionary:
	var root = _current_root()
	var scenes: Array[String] = []
	if root != null:
		scenes.append(str(root.scene_file_path))
	return _ok({"scenes": scenes})

func _scene_open(params: Dictionary) -> Dictionary:
	var path_result = _guard.normalize_res_path(str(params.get("path", "")))
	if not path_result.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(path_result.get("error", "Invalid path")))
	var path = str(path_result.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "Scene does not exist: %s" % path)
	_plugin.get_editor_interface().open_scene_from_path(path)
	return _ok({"opened": path})

func _scene_new() -> Dictionary:
	var iface := _plugin.get_editor_interface()
	if iface.has_method("new_scene"):
		iface.call("new_scene")
		return _ok({"created": true})
	var fallback_path := "res://.godot_mcp_tmp/new_scene.tscn"
	var fallback_scene := "[gd_scene format=3]\n\n[node name=\"Main\" type=\"Node2D\"]\n"
	var write_result = _write_text_file(fallback_path, fallback_scene)
	if not write_result.get("ok", false):
		return _err(ERR_EDITOR_BUSY, "scene.new is not supported and fallback failed")
	iface.open_scene_from_path(fallback_path)
	return _ok({"created": true, "fallback": true, "path": fallback_path})

func _scene_save(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var path = str(params.get("path", ""))
	if path == "":
		path = str(root.scene_file_path)
	if path == "":
		return _err(RPC_INVALID_PARAMS, "Unsaved scene. Provide path.")

	var normalized = _guard.normalize_res_path(path)
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))

	var packed = PackedScene.new()
	var pack_err = packed.pack(root)
	if pack_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to pack scene", {"error": pack_err})

	var target_path = str(normalized.get("path", ""))
	var target_dir = ProjectSettings.globalize_path(target_path).get_base_dir()
	var mk_err = DirAccess.make_dir_recursive_absolute(target_dir)
	if mk_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to create scene directory", {"error": mk_err, "path": target_dir})
	var save_err = ResourceSaver.save(packed, target_path)
	if save_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save scene", {"error": save_err})

	root.scene_file_path = target_path
	if _undo_action_open and _undo_scene_original_path == "":
		_undo_scene_original_path = target_path
	return _ok({"saved": target_path})

func _scene_save_as(params: Dictionary) -> Dictionary:
	if not params.has("path"):
		return _err(RPC_INVALID_PARAMS, "Missing path")
	return _scene_save(params)

func _scene_close() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface.has_method("close_scene"):
		iface.call("close_scene")
		return _ok({"closed": true})
	_state.record_warning("scene.close is not supported in this Godot build")
	return _ok({"closed": false, "warning": "Not supported by this Godot build"})

func _scene_close_all() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if not iface.has_method("close_scene"):
		_state.record_warning("scene.close_all is not supported in this Godot build")
		return _ok({"closed_count": 0, "warning": "Not supported by this Godot build"})

	var closed_count := 0
	# Current bridge tracks one edited scene root; close repeatedly as a best effort.
	for _i in range(0, 8):
		var root = _current_root()
		if root == null:
			break
		iface.call("close_scene")
		closed_count += 1
	return _ok({"closed_count": closed_count})

func _scene_get_tree() -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	return _ok({"tree": _serialize_tree(root)})

func _scene_find_nodes(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var name_contains = str(params.get("name_contains", ""))
	var type_is = str(params.get("type", ""))
	var max_results = int(params.get("max_results", 50))
	max_results = clamp(max_results, 1, 1000)

	var matches: Array[Dictionary] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0 and matches.size() < max_results:
		var current = stack.pop_back()
		var name_ok = name_contains == "" or current.name.contains(name_contains)
		var type_ok = type_is == "" or current.is_class(type_is)
		if name_ok and type_ok:
			matches.append({
				"name": current.name,
				"path": str(current.get_path()),
				"type": current.get_class(),
			})
		for child in current.get_children():
			if child is Node:
				stack.append(child)

	return _ok({"matches": matches, "count": matches.size()})

func _scene_instantiate(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	if not params.has("scene_path"):
		return _err(RPC_INVALID_PARAMS, "Missing scene_path")

	var scene_norm = _guard.normalize_res_path(str(params.get("scene_path", "")))
	if not scene_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(scene_norm.get("error", "Invalid path")))
	var scene_path = str(scene_norm.get("path", ""))

	var packed = ResourceLoader.load(scene_path)
	if packed == null or not (packed is PackedScene):
		return _err(RPC_INVALID_PARAMS, "Failed to load PackedScene: %s" % scene_path)

	var parent_path = str(params.get("parent_path", "."))
	var parent = _resolve_node(root, parent_path)
	if parent == null:
		return _err(RPC_INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var instance = packed.instantiate()
	if not (instance is Node):
		return _err(ERR_EDITOR_BUSY, "PackedScene did not instantiate a Node")

	var instance_name = str(params.get("instance_name", ""))
	if instance_name != "":
		instance.name = instance_name
	parent.add_child(instance)
	instance.owner = root

	return _ok({
		"scene_path": scene_path,
		"path": str(instance.get_path()),
		"name": instance.name,
	})

func _scene_instances_list(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var parent_path = str(params.get("parent_path", "."))
	var parent = _resolve_node(root, parent_path)
	if parent == null:
		return _err(RPC_INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var filter_scene_path := ""
	if params.has("filter_scene_path"):
		var filter_norm = _guard.normalize_res_path(str(params.get("filter_scene_path", "")))
		if not filter_norm.get("ok", false):
			return _err(ERR_PATH_VIOLATION, str(filter_norm.get("error", "Invalid filter_scene_path")))
		filter_scene_path = str(filter_norm.get("path", ""))

	var instances = _collect_scene_instance_nodes(parent, root, filter_scene_path)
	return _ok({
		"parent_path": str(parent.get_path()),
		"filter_scene_path": filter_scene_path,
		"count": instances.size(),
		"items": instances,
	})

func _scene_instances_replace(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	if not params.has("target_scene_path") or not params.has("replacement_scene_path"):
		return _err(RPC_INVALID_PARAMS, "Missing target_scene_path or replacement_scene_path")

	var target_norm = _guard.normalize_res_path(str(params.get("target_scene_path", "")))
	var replacement_norm = _guard.normalize_res_path(str(params.get("replacement_scene_path", "")))
	if not target_norm.get("ok", false) or not replacement_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, "Invalid target/replacement scene path")

	var target_scene_path = str(target_norm.get("path", ""))
	var replacement_scene_path = str(replacement_norm.get("path", ""))
	if target_scene_path == replacement_scene_path:
		return _err(RPC_INVALID_PARAMS, "target_scene_path and replacement_scene_path cannot be the same")
	if not FileAccess.file_exists(target_scene_path):
		return _err(RPC_INVALID_PARAMS, "Target scene does not exist: %s" % target_scene_path)
	if not FileAccess.file_exists(replacement_scene_path):
		return _err(RPC_INVALID_PARAMS, "Replacement scene does not exist: %s" % replacement_scene_path)

	var parent_path = str(params.get("parent_path", "."))
	var parent = _resolve_node(root, parent_path)
	if parent == null:
		return _err(RPC_INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var replacement = ResourceLoader.load(replacement_scene_path)
	if replacement == null or not (replacement is PackedScene):
		return _err(RPC_INVALID_PARAMS, "Failed to load replacement PackedScene: %s" % replacement_scene_path)

	var dry_run = bool(params.get("dry_run", false))
	var candidates = _collect_scene_instance_node_refs(parent, root, target_scene_path)
	var results: Array[Dictionary] = []
	var replaced := 0
	var failed := 0

	for item in candidates:
		var node_path = str(item.get("path", ""))
		var node_name = str(item.get("name", ""))
		if dry_run:
			results.append({
				"path": node_path,
				"name": node_name,
				"target_scene_path": target_scene_path,
				"replacement_scene_path": replacement_scene_path,
				"ok": true,
				"planned": true,
			})
			continue

		var old_node = root.get_node_or_null(NodePath(node_path))
		if old_node == null:
			failed += 1
			results.append({"path": node_path, "name": node_name, "ok": false, "error": "Node no longer exists"})
			continue
		var old_parent = old_node.get_parent()
		if old_parent == null:
			failed += 1
			results.append({"path": node_path, "name": node_name, "ok": false, "error": "Node has no parent"})
			continue

		var new_node = replacement.instantiate()
		if not (new_node is Node):
			failed += 1
			results.append({"path": node_path, "name": node_name, "ok": false, "error": "Replacement did not instantiate a Node"})
			continue

		var old_index = old_node.get_index()
		old_parent.add_child(new_node)
		old_parent.move_child(new_node, old_index)
		new_node.name = old_node.name
		_copy_node_runtime_state(old_node, new_node)
		new_node.owner = old_node.owner if old_node.owner != null else root

		old_parent.remove_child(old_node)
		old_node.queue_free()

		replaced += 1
		if _undo_action_open and not _undo_replaying:
			_undo_change_count += 1
		results.append({
			"path": node_path,
			"name": node_name,
			"ok": true,
			"planned": false,
			"replacement_path": str(new_node.get_path()),
		})

	return _ok({
		"target_scene_path": target_scene_path,
		"replacement_scene_path": replacement_scene_path,
		"parent_path": str(parent.get_path()),
		"dry_run": dry_run,
		"count": candidates.size(),
		"replaced_count": replaced,
		"failed_count": failed,
		"items": results,
	})

func _scene_owners_repair(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var dry_run = bool(params.get("dry_run", false))
	var include_orphans = bool(params.get("include_orphans", true))
	var stack: Array[Node] = [root]
	var fixed := 0
	var planned := 0
	var items: Array[Dictionary] = []

	while stack.size() > 0:
		var current = stack.pop_back()
		for child in current.get_children():
			if child is Node:
				stack.append(child)
		if current == root:
			continue

		var current_owner: Node = current.owner
		var old_owner_path := ""
		if current_owner != null:
			old_owner_path = str(current_owner.get_path())

		var should_fix := false
		if current_owner == null:
			should_fix = include_orphans
		else:
			should_fix = not current_owner.is_ancestor_of(current)
		if not should_fix:
			continue

		planned += 1
		if not dry_run:
			current.owner = root
			fixed += 1
			if _undo_action_open and not _undo_replaying:
				_undo_change_count += 1
		items.append({
			"path": str(current.get_path()),
			"old_owner_path": old_owner_path,
			"new_owner_path": str(root.get_path()),
			"applied": not dry_run,
		})

	return _ok({
		"dry_run": dry_run,
		"include_orphans": include_orphans,
		"planned_count": planned,
		"fixed_count": fixed,
		"items": items,
	})

func _scene_paths_normalize(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var dry_run = bool(params.get("dry_run", false))
	var updated := 0
	var failed := 0
	var items: Array[Dictionary] = []
	var stack: Array[Node] = [root]

	while stack.size() > 0:
		var current = stack.pop_back()
		for child in current.get_children():
			if child is Node:
				stack.append(child)

		var script_res = current.get_script()
		if script_res == null or not (script_res is Script):
			continue
		var old_script_path = str(script_res.resource_path)
		if old_script_path == "":
			continue

		var normalized = _guard.normalize_res_path(old_script_path)
		if not normalized.get("ok", false):
			failed += 1
			items.append({
				"path": str(current.get_path()),
				"old_path": old_script_path,
				"ok": false,
				"error": str(normalized.get("error", "Invalid script path")),
			})
			continue
		var new_script_path = str(normalized.get("path", ""))
		if new_script_path == old_script_path:
			continue

		var row = {
			"path": str(current.get_path()),
			"old_path": old_script_path,
			"new_path": new_script_path,
			"ok": true,
			"applied": not dry_run,
		}
		if not dry_run:
			var loaded = ResourceLoader.load(new_script_path)
			if loaded == null or not (loaded is Script):
				row["ok"] = false
				row["error"] = "Failed to load normalized script"
				failed += 1
				items.append(row)
				continue
			current.set_script(loaded)
			updated += 1
			if _undo_action_open and not _undo_replaying:
				_undo_change_count += 1
		items.append(row)

	return _ok({
		"dry_run": dry_run,
		"updated_count": updated,
		"failed_count": failed,
		"items": items,
	})

func _scene_dependencies_list(params: Dictionary) -> Dictionary:
	var scene_path = str(params.get("scene_path", ""))
	if scene_path == "":
		var root = _current_root()
		if root == null:
			return _err(ERR_SCENE_CONTEXT, "No edited scene")
		scene_path = str(root.scene_file_path)
		if scene_path == "":
			return _err(RPC_INVALID_PARAMS, "Current scene has no file path")

	var normalized = _guard.normalize_res_path(scene_path)
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid scene path")))
	var normalized_scene_path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(normalized_scene_path):
		return _err(RPC_INVALID_PARAMS, "Scene does not exist: %s" % normalized_scene_path)

	var deps: PackedStringArray = ResourceLoader.get_dependencies(normalized_scene_path)
	var items: Array[String] = []
	for dep in deps:
		items.append(str(dep))
	return _ok({"scene_path": normalized_scene_path, "count": items.size(), "dependencies": items})

func _animation_players_list(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var start_path = str(params.get("start_path", "."))
	var start_node = _resolve_node(root, start_path)
	if start_node == null:
		return _err(RPC_INVALID_PARAMS, "Start node not found: %s" % start_path)

	var items: Array[Dictionary] = []
	var stack: Array[Node] = [start_node]
	while stack.size() > 0:
		var current = stack.pop_back()
		if current is AnimationPlayer:
			var player: AnimationPlayer = current
			var anim_count := 0
			var library = player.get_animation_library("")
			if library != null:
				anim_count = library.get_animation_list().size()
			items.append(
				{
					"name": player.name,
					"path": str(player.get_path()),
					"animation_count": anim_count,
				}
			)
		for child in current.get_children():
			if child is Node:
				stack.append(child)
	return _ok({"start_path": str(start_node.get_path()), "count": items.size(), "items": items})

func _animation_players_create(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var parent_path = str(params.get("parent_path", "."))
	var parent = _resolve_node(root, parent_path)
	if parent == null:
		return _err(RPC_INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var player := AnimationPlayer.new()
	player.name = str(params.get("name", "AnimationPlayer")).strip_edges()
	if player.name == "":
		player.name = "AnimationPlayer"
	parent.add_child(player)
	player.owner = root
	var ensure_library = _animation_get_or_create_default_library(player)
	if not ensure_library.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(ensure_library.get("error", "Failed to initialize animation library")))
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"path": str(player.get_path()), "name": player.name})

func _animation_animations_list(params: Dictionary) -> Dictionary:
	var resolved = _animation_resolve_player(params)
	if not resolved.get("ok", false):
		return _err(int(resolved.get("code", RPC_INVALID_PARAMS)), str(resolved.get("message", "AnimationPlayer not found")))
	var player: AnimationPlayer = resolved.get("player", null)
	var ensure_library = _animation_get_or_create_default_library(player)
	if not ensure_library.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(ensure_library.get("error", "Failed to access animation library")))
	var library: AnimationLibrary = ensure_library.get("library", null)
	var items: Array[Dictionary] = []
	for anim_name_item in library.get_animation_list():
		var anim_name = str(anim_name_item)
		var anim = library.get_animation(anim_name)
		if anim == null:
			continue
		items.append(
			{
				"name": anim_name,
				"length": float(anim.length),
				"loop_mode": _animation_loop_mode_name(int(anim.loop_mode)),
				"track_count": int(anim.get_track_count()),
				"step": float(anim.step),
			}
		)
	return _ok({"player_path": str(player.get_path()), "count": items.size(), "items": items})

func _animation_animations_create(params: Dictionary) -> Dictionary:
	var resolved = _animation_resolve_player(params)
	if not resolved.get("ok", false):
		return _err(int(resolved.get("code", RPC_INVALID_PARAMS)), str(resolved.get("message", "AnimationPlayer not found")))
	var player: AnimationPlayer = resolved.get("player", null)
	var anim_name = str(params.get("animation_name", "")).strip_edges()
	if anim_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing animation_name")
	var ensure_library = _animation_get_or_create_default_library(player)
	if not ensure_library.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(ensure_library.get("error", "Failed to access animation library")))
	var library: AnimationLibrary = ensure_library.get("library", null)
	if library.has_animation(anim_name):
		return _err(RPC_INVALID_PARAMS, "Animation already exists: %s" % anim_name)

	var animation := Animation.new()
	animation.length = max(0.0, float(params.get("length", 1.0)))
	animation.loop_mode = _animation_parse_loop_mode(params.get("loop_mode", params.get("loop", false)))
	var add_err = library.add_animation(anim_name, animation)
	if add_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to create animation", {"error": add_err})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"player_path": str(player.get_path()),
			"animation_name": anim_name,
			"length": float(animation.length),
			"loop_mode": _animation_loop_mode_name(int(animation.loop_mode)),
		}
	)

func _animation_animations_remove(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var player: AnimationPlayer = resolved_animation.get("player", null)
	var library: AnimationLibrary = resolved_animation.get("library", null)
	var animation_name = str(resolved_animation.get("animation_name", ""))
	library.remove_animation(animation_name)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"player_path": str(player.get_path()), "animation_name": animation_name, "removed": true})

func _animation_tracks_list(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var player: AnimationPlayer = resolved_animation.get("player", null)
	var animation: Animation = resolved_animation.get("animation", null)
	var animation_name = str(resolved_animation.get("animation_name", ""))
	var items: Array[Dictionary] = []
	for i in range(animation.get_track_count()):
		var track_path := ""
		if animation.track_get_type(i) != Animation.TYPE_ANIMATION:
			track_path = str(animation.track_get_path(i))
		items.append(
			{
				"track_index": i,
				"track_type": _animation_track_type_name(int(animation.track_get_type(i))),
				"track_path": track_path,
				"key_count": int(animation.track_get_key_count(i)),
			}
		)
	return _ok({"player_path": str(player.get_path()), "animation_name": animation_name, "count": items.size(), "items": items})

func _animation_tracks_add(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var track_type = _animation_parse_track_type(str(params.get("track_type", "value")))
	if track_type == -1:
		return _err(RPC_INVALID_PARAMS, "Unsupported track_type")
	var at_index = int(params.get("at_index", -1))
	var track_index = animation.add_track(track_type, at_index)
	if track_index < 0:
		return _err(ERR_EDITOR_BUSY, "Failed to add track")
	if params.has("track_path"):
		animation.track_set_path(track_index, NodePath(str(params.get("track_path", ""))))
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"animation_name": str(resolved_animation.get("animation_name", "")),
			"track_index": track_index,
			"track_type": _animation_track_type_name(track_type),
			"track_path": "" if not params.has("track_path") else str(params.get("track_path", "")),
		}
	)

func _animation_tracks_remove(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var track_index = int(params.get("track_index", -1))
	if track_index < 0 or track_index >= animation.get_track_count():
		return _err(RPC_INVALID_PARAMS, "Invalid track_index")
	animation.remove_track(track_index)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"animation_name": str(resolved_animation.get("animation_name", "")), "track_index": track_index, "removed": true})

func _animation_keys_insert(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var track_index = int(params.get("track_index", -1))
	if track_index < 0 or track_index >= animation.get_track_count():
		return _err(RPC_INVALID_PARAMS, "Invalid track_index")
	var time_value = max(0.0, float(params.get("time", 0.0)))
	var key_value = _decode_value(params.get("value", null))
	var key_index = animation.track_insert_key(track_index, time_value, key_value)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"animation_name": str(resolved_animation.get("animation_name", "")),
			"track_index": track_index,
			"key_index": int(key_index),
			"time": time_value,
		}
	)

func _animation_keys_remove(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var track_index = int(params.get("track_index", -1))
	var key_index = int(params.get("key_index", -1))
	if track_index < 0 or track_index >= animation.get_track_count():
		return _err(RPC_INVALID_PARAMS, "Invalid track_index")
	var key_count = int(animation.track_get_key_count(track_index))
	if key_index < 0 or key_index >= key_count:
		return _err(RPC_INVALID_PARAMS, "Invalid key_index")
	animation.track_remove_key(track_index, key_index)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"animation_name": str(resolved_animation.get("animation_name", "")), "track_index": track_index, "key_index": key_index, "removed": true})

func _animation_keys_clear_range(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var track_index = int(params.get("track_index", -1))
	if track_index < 0 or track_index >= animation.get_track_count():
		return _err(RPC_INVALID_PARAMS, "Invalid track_index")
	var time_from = float(params.get("time_from", 0.0))
	var time_to = float(params.get("time_to", animation.length))
	if time_to < time_from:
		var swap = time_from
		time_from = time_to
		time_to = swap
	var include_edges = bool(params.get("include_edges", true))
	var removed := 0
	for i in range(animation.track_get_key_count(track_index) - 1, -1, -1):
		var key_time = float(animation.track_get_key_time(track_index, i))
		var in_range = key_time >= time_from and key_time <= time_to if include_edges else key_time > time_from and key_time < time_to
		if in_range:
			animation.track_remove_key(track_index, i)
			removed += 1
	if removed > 0 and _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"animation_name": str(resolved_animation.get("animation_name", "")),
			"track_index": track_index,
			"time_from": time_from,
			"time_to": time_to,
			"removed_count": removed,
		}
	)

func _animation_length_set(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var length_value = max(0.0, float(params.get("length", animation.length)))
	var previous = float(animation.length)
	animation.length = length_value
	if previous != length_value and _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"animation_name": str(resolved_animation.get("animation_name", "")),
			"length": float(animation.length),
			"previous_length": previous,
		}
	)

func _animation_loop_set(params: Dictionary) -> Dictionary:
	var resolved_animation = _animation_resolve_animation(params)
	if not resolved_animation.get("ok", false):
		return _err(int(resolved_animation.get("code", RPC_INVALID_PARAMS)), str(resolved_animation.get("message", "Animation not found")))
	var animation: Animation = resolved_animation.get("animation", null)
	var previous = int(animation.loop_mode)
	var loop_mode = _animation_parse_loop_mode(params.get("loop_mode", params.get("loop", false)))
	animation.loop_mode = loop_mode
	if previous != loop_mode and _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"animation_name": str(resolved_animation.get("animation_name", "")),
			"loop_mode": _animation_loop_mode_name(int(animation.loop_mode)),
			"previous_loop_mode": _animation_loop_mode_name(previous),
		}
	)

func _animation_preview_play(params: Dictionary) -> Dictionary:
	var resolved = _animation_resolve_player(params)
	if not resolved.get("ok", false):
		return _err(int(resolved.get("code", RPC_INVALID_PARAMS)), str(resolved.get("message", "AnimationPlayer not found")))
	var player: AnimationPlayer = resolved.get("player", null)
	var animation_name = str(params.get("animation_name", "")).strip_edges()
	if animation_name == "":
		var ensure_library = _animation_get_or_create_default_library(player)
		if not ensure_library.get("ok", false):
			return _err(ERR_EDITOR_BUSY, str(ensure_library.get("error", "Failed to access animation library")))
		var library: AnimationLibrary = ensure_library.get("library", null)
		var names = library.get_animation_list()
		if names.is_empty():
			return _err(RPC_INVALID_PARAMS, "AnimationPlayer has no animations")
		animation_name = str(names[0])
	player.play(animation_name)
	return _ok({"player_path": str(player.get_path()), "animation_name": animation_name, "playing": true})

func _animation_preview_stop(params: Dictionary) -> Dictionary:
	var resolved = _animation_resolve_player(params)
	if not resolved.get("ok", false):
		return _err(int(resolved.get("code", RPC_INVALID_PARAMS)), str(resolved.get("message", "AnimationPlayer not found")))
	var player: AnimationPlayer = resolved.get("player", null)
	player.stop()
	return _ok({"player_path": str(player.get_path()), "playing": false})

func _node_add(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var parent_path = str(params.get("parent_path", "."))
	var parent = _resolve_node(root, parent_path)
	if parent == null:
		return _err(RPC_INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var node_type = str(params.get("type", "Node"))
	if not ClassDB.can_instantiate(node_type):
		return _err(RPC_INVALID_PARAMS, "Cannot instantiate type: %s" % node_type)

	var new_node = ClassDB.instantiate(node_type)
	if not (new_node is Node):
		return _err(RPC_INVALID_PARAMS, "Type is not a Node: %s" % node_type)

	new_node.name = str(params.get("name", "NewNode"))
	parent.add_child(new_node)
	new_node.owner = root

	var properties = params.get("properties", {})
	if typeof(properties) == TYPE_DICTIONARY:
		for key in properties.keys():
			new_node.set(str(key), _decode_value(properties[key]))

	_undo_register_node_added(str(new_node.get_path()))
	return _ok({
		"name": new_node.name,
		"type": node_type,
		"path": str(new_node.get_path()),
	})

func _node_remove(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var node_path = str(params.get("node_path", ""))
	if node_path == "" or node_path == ".":
		return _err(RPC_INVALID_PARAMS, "Refusing to remove scene root")

	var node = _resolve_node(root, node_path)
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found: %s" % node_path)
	if node == root:
		return _err(RPC_INVALID_PARAMS, "Refusing to remove scene root")

	var parent = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	_undo_register_node_removed_snapshot(node, parent)
	node.queue_free()
	return _ok({"removed": node_path})

func _node_duplicate(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var node_path = str(params.get("node_path", ""))
	var node = _resolve_node(root, node_path)
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found: %s" % node_path)

	var parent = node.get_parent()
	if parent == null:
		return _err(ERR_EDITOR_BUSY, "Node has no parent")

	var dup = node.duplicate()
	if not (dup is Node):
		return _err(ERR_EDITOR_BUSY, "Failed to duplicate node")
	if params.has("new_name"):
		dup.name = str(params.get("new_name", ""))
	parent.add_child(dup)
	dup.owner = root
	return _ok({"duplicated_path": str(dup.get_path())})

func _node_reparent(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var node = _resolve_node(root, str(params.get("node_path", "")))
	var new_parent = _resolve_node(root, str(params.get("new_parent_path", "")))
	if node == null or new_parent == null:
		return _err(RPC_INVALID_PARAMS, "Node or new parent not found")
	if node == root:
		return _err(RPC_INVALID_PARAMS, "Cannot reparent root")

	var old_parent = node.get_parent()
	var old_parent_path := ""
	if old_parent != null:
		old_parent_path = str(old_parent.get_path())
	if old_parent != null:
		old_parent.remove_child(node)
	new_parent.add_child(node)
	node.owner = root
	_undo_register_node_reparent(str(node.get_path()), old_parent_path)
	return _ok({"path": str(node.get_path())})

func _node_rename(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var new_name = str(params.get("new_name", ""))
	if new_name == "":
		return _err(RPC_INVALID_PARAMS, "new_name cannot be empty")
	var old_name = str(node.name)
	node.name = new_name
	_undo_register_node_rename(str(node.get_path()), old_name)
	return _ok({"path": str(node.get_path()), "name": new_name})

func _node_set_owner(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var owner_path = str(params.get("owner_path", "."))
	var owner = _resolve_node(root, owner_path)
	if owner == null:
		return _err(RPC_INVALID_PARAMS, "Owner not found")
	node.owner = owner
	return _ok({"node_path": str(node.get_path()), "owner_path": str(owner.get_path())})

func _node_get_properties(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")

	var properties: Array[Dictionary] = []
	for item in node.get_property_list():
		var name = str(item.get("name", ""))
		if name.begins_with("_"):
			continue
		var value = node.get(name)
		properties.append({
			"name": name,
			"type": int(item.get("type", TYPE_NIL)),
			"usage": int(item.get("usage", 0)),
			"value": _encode_value(value),
		})
	return _ok({"node_path": str(node.get_path()), "properties": properties})

func _node_set_property(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	if not params.has("property"):
		return _err(RPC_INVALID_PARAMS, "Missing property")

	var property_name = str(params.get("property", ""))
	var value = _decode_value(params.get("value", null))
	var previous_value = node.get(property_name)
	node.set(property_name, value)
	_undo_register_node_property(str(node.get_path()), property_name, previous_value)
	return _ok({"node_path": str(node.get_path()), "property": property_name})

func _node_batch_set_property(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")

	var properties = params.get("properties", {})
	if typeof(properties) != TYPE_DICTIONARY:
		return _err(RPC_INVALID_PARAMS, "properties must be a dictionary")

	var updated: Array[String] = []
	var old_values: Dictionary = {}
	for key in properties.keys():
		var property_name = str(key)
		old_values[property_name] = node.get(property_name)
		node.set(property_name, _decode_value(properties[key]))
		updated.append(property_name)
	_undo_register_node_properties(str(node.get_path()), old_values)
	return _ok({"node_path": str(node.get_path()), "updated": updated, "count": updated.size()})

func _node_signals_list(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")

	var include_connections = bool(params.get("include_connections", true))
	var items: Array[Dictionary] = []
	for signal_info in node.get_signal_list():
		if typeof(signal_info) != TYPE_DICTIONARY:
			continue
		var signal_name = str(signal_info.get("name", ""))
		if signal_name == "":
			continue

		var args: Array[Dictionary] = []
		var raw_args = signal_info.get("args", [])
		if typeof(raw_args) == TYPE_ARRAY:
			for arg_info in raw_args:
				if typeof(arg_info) == TYPE_DICTIONARY:
					args.append(
						{
							"name": str(arg_info.get("name", "")),
							"type": int(arg_info.get("type", TYPE_NIL)),
						}
					)

		var row = {
			"name": signal_name,
			"arg_count": args.size(),
			"args": args,
		}
		if include_connections:
			var connections: Array[Dictionary] = []
			var raw_connections = node.get_signal_connection_list(signal_name)
			if typeof(raw_connections) == TYPE_ARRAY:
				for conn in raw_connections:
					if typeof(conn) != TYPE_DICTIONARY:
						continue
					var target_path := ""
					var method_name := ""
					var callable_value = conn.get("callable", null)
					if callable_value is Callable:
						var callable_obj: Callable = callable_value
						method_name = str(callable_obj.get_method())
						var target_obj = callable_obj.get_object()
						if target_obj is Node:
							target_path = str(target_obj.get_path())
					connections.append(
						{
							"target_path": target_path,
							"method": method_name,
							"flags": int(conn.get("flags", 0)),
						}
					)
			row["connections"] = connections
			row["connection_count"] = connections.size()
		items.append(row)
	return _ok({"node_path": str(node.get_path()), "count": items.size(), "items": items})

func _node_signals_connect(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var signal_name = str(params.get("signal_name", "")).strip_edges()
	if signal_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing signal_name")
	if not node.has_signal(signal_name):
		return _err(RPC_INVALID_PARAMS, "Node does not have signal: %s" % signal_name)

	var target = _resolve_node(root, str(params.get("target_path", ".")))
	if target == null:
		return _err(RPC_INVALID_PARAMS, "Target node not found")
	var method_name = str(params.get("method", "")).strip_edges()
	if method_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing method")

	var callable_obj := Callable(target, method_name)
	if node.is_connected(signal_name, callable_obj):
		return _ok(
			{
				"node_path": str(node.get_path()),
				"signal_name": signal_name,
				"target_path": str(target.get_path()),
				"method": method_name,
				"connected": false,
				"already_connected": true,
			}
		)

	var flags = int(params.get("flags", 0))
	var connect_err = node.connect(signal_name, callable_obj, flags)
	if connect_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to connect signal", {"error": connect_err})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"node_path": str(node.get_path()),
			"signal_name": signal_name,
			"target_path": str(target.get_path()),
			"method": method_name,
			"flags": flags,
			"connected": true,
		}
	)

func _node_signals_disconnect(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var signal_name = str(params.get("signal_name", "")).strip_edges()
	if signal_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing signal_name")
	if not node.has_signal(signal_name):
		return _err(RPC_INVALID_PARAMS, "Node does not have signal: %s" % signal_name)

	var target = _resolve_node(root, str(params.get("target_path", ".")))
	if target == null:
		return _err(RPC_INVALID_PARAMS, "Target node not found")
	var method_name = str(params.get("method", "")).strip_edges()
	if method_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing method")

	var callable_obj := Callable(target, method_name)
	if not node.is_connected(signal_name, callable_obj):
		return _ok(
			{
				"node_path": str(node.get_path()),
				"signal_name": signal_name,
				"target_path": str(target.get_path()),
				"method": method_name,
				"disconnected": false,
				"was_connected": false,
			}
		)

	node.disconnect(signal_name, callable_obj)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"node_path": str(node.get_path()),
			"signal_name": signal_name,
			"target_path": str(target.get_path()),
			"method": method_name,
			"disconnected": true,
			"was_connected": true,
		}
	)

func _node_groups_list(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")

	var include_internal = bool(params.get("include_internal", false))
	var groups: Array[String] = []
	for group_item in node.get_groups():
		var group_name = str(group_item)
		if group_name == "":
			continue
		if not include_internal and group_name.begins_with("_"):
			continue
		groups.append(group_name)
	return _ok({"node_path": str(node.get_path()), "count": groups.size(), "groups": groups})

func _node_groups_add(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var group_name = str(params.get("group_name", "")).strip_edges()
	if group_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing group_name")
	var persistent = bool(params.get("persistent", true))
	if node.is_in_group(group_name):
		return _ok(
			{
				"node_path": str(node.get_path()),
				"group_name": group_name,
				"added": false,
				"already_in_group": true,
				"persistent": persistent,
			}
		)
	node.add_to_group(group_name, persistent)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"node_path": str(node.get_path()),
			"group_name": group_name,
			"added": true,
			"already_in_group": false,
			"persistent": persistent,
		}
	)

func _node_groups_remove(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var group_name = str(params.get("group_name", "")).strip_edges()
	if group_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing group_name")
	var was_in_group = node.is_in_group(group_name)
	if was_in_group:
		node.remove_from_group(group_name)
		if _undo_action_open and not _undo_replaying:
			_undo_change_count += 1
	return _ok(
		{
			"node_path": str(node.get_path()),
			"group_name": group_name,
			"removed": was_in_group,
			"was_in_group": was_in_group,
		}
	)

func _inspector_schema_get(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")

	var include_private = bool(params.get("include_private", false))
	var items: Array[Dictionary] = []
	for prop in node.get_property_list():
		if typeof(prop) != TYPE_DICTIONARY:
			continue
		var name = str(prop.get("name", ""))
		if name == "":
			continue
		if not include_private and name.begins_with("_"):
			continue
		items.append(
			{
				"name": name,
				"type": int(prop.get("type", TYPE_NIL)),
				"usage": int(prop.get("usage", 0)),
				"hint": int(prop.get("hint", 0)),
				"hint_string": str(prop.get("hint_string", "")),
				"class_name": str(prop.get("class_name", "")),
			}
		)
	return _ok({"node_path": str(node.get_path()), "count": items.size(), "items": items})

func _inspector_schema_get_filtered(params: Dictionary) -> Dictionary:
	var schema = _inspector_schema_get(params)
	if not schema.get("ok", false):
		return schema
	var data = schema.get("data", {})
	var raw_items = data.get("items", [])
	if typeof(raw_items) != TYPE_ARRAY:
		return _ok({"node_path": data.get("node_path", ""), "count": 0, "items": []})

	var contains = str(params.get("contains", "")).to_lower()
	var type_hint = str(params.get("type_hint", "")).to_lower()
	var exported_only = bool(params.get("exported_only", false))
	var script_only = bool(params.get("script_only", false))
	var filtered: Array[Dictionary] = []
	for item in raw_items:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var name = str(item.get("name", ""))
		var usage = int(item.get("usage", 0))
		var class_name_text = str(item.get("class_name", "")).to_lower()
		var hint_text = str(item.get("hint_string", "")).to_lower()
		var type_name = _variant_type_name(int(item.get("type", TYPE_NIL))).to_lower()

		if contains != "" and name.to_lower().find(contains) == -1:
			continue
		if exported_only and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if script_only and (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		if type_hint != "":
			var hay = "%s %s %s" % [type_name, class_name_text, hint_text]
			if hay.find(type_hint) == -1:
				continue
		filtered.append(item)
	return _ok(
		{
			"node_path": str(data.get("node_path", "")),
			"count": filtered.size(),
			"items": filtered,
			"filters": {
				"contains": contains,
				"type_hint": type_hint,
				"exported_only": exported_only,
				"script_only": script_only,
			},
		}
	)

func _inspector_values_get(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")

	var allowed_names: Dictionary = {}
	for prop in node.get_property_list():
		if typeof(prop) == TYPE_DICTIONARY:
			allowed_names[str(prop.get("name", ""))] = true

	var names: Array[String] = []
	var requested = params.get("properties", [])
	if typeof(requested) == TYPE_ARRAY and requested.size() > 0:
		for raw_name in requested:
			var property_name = str(raw_name)
			if property_name == "":
				continue
			if allowed_names.has(property_name):
				names.append(property_name)
	else:
		var include_private = bool(params.get("include_private", false))
		for key in allowed_names.keys():
			var name = str(key)
			if not include_private and name.begins_with("_"):
				continue
			names.append(name)
		names.sort()

	var values: Dictionary = {}
	for property_name in names:
		values[property_name] = _encode_value(node.get(property_name))
	return _ok({"node_path": str(node.get_path()), "count": names.size(), "values": values})

func _inspector_values_patch(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var raw_patches = params.get("patches", [])
	if typeof(raw_patches) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "patches must be an array")

	var atomic = bool(params.get("atomic", true))
	var validate_only = bool(params.get("validate_only", false))
	var known_names: Dictionary = {}
	for prop in node.get_property_list():
		if typeof(prop) == TYPE_DICTIONARY:
			known_names[str(prop.get("name", ""))] = true

	var prepared: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	for patch_item in raw_patches:
		if typeof(patch_item) != TYPE_DICTIONARY:
			errors.append({"ok": false, "error": "patch item must be a dictionary"})
			continue
		var path = str(patch_item.get("path", "")).strip_edges()
		if path == "":
			errors.append({"ok": false, "error": "patch.path is required"})
			continue
		if not known_names.has(path):
			errors.append({"ok": false, "path": path, "error": "Unknown property"})
			continue
		prepared.append(
			{
				"path": path,
				"value": _decode_value(patch_item.get("value", null)),
			}
		)

	if atomic and errors.size() > 0:
		return _err(RPC_INVALID_PARAMS, "Patch validation failed", {"errors": errors, "validated_count": prepared.size()})
	if validate_only:
		return _ok(
			{
				"node_path": str(node.get_path()),
				"atomic": atomic,
				"validate_only": true,
				"validated_count": prepared.size(),
				"error_count": errors.size(),
				"errors": errors,
			}
		)

	var old_values: Dictionary = {}
	var applied: Array[Dictionary] = []
	for item in prepared:
		var property_name = str(item.get("path", ""))
		old_values[property_name] = node.get(property_name)
		node.set(property_name, item.get("value", null))
		applied.append(
			{
				"path": property_name,
				"value": _encode_value(node.get(property_name)),
			}
		)

	if old_values.size() > 0:
		_undo_register_node_properties(str(node.get_path()), old_values)
	return _ok(
		{
			"node_path": str(node.get_path()),
			"atomic": atomic,
			"validate_only": false,
			"applied_count": applied.size(),
			"error_count": errors.size(),
			"items": applied,
			"errors": errors,
		}
	)

func _inspector_values_patch_preview(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var raw_patches = params.get("patches", [])
	if typeof(raw_patches) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "patches must be an array")
	var atomic = bool(params.get("atomic", true))

	var preview = _inspector_preview_node_patches(node, raw_patches)
	preview["node_path"] = str(node.get_path())
	preview["atomic"] = atomic
	preview["would_apply"] = bool(preview.get("error_count", 0) == 0 or not atomic)
	return _ok(preview)

func _inspector_values_diff(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", ".")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var values = params.get("values", {})
	if typeof(values) != TYPE_DICTIONARY:
		return _err(RPC_INVALID_PARAMS, "values must be a dictionary")

	var known_names: Dictionary = {}
	for prop in node.get_property_list():
		if typeof(prop) == TYPE_DICTIONARY:
			known_names[str(prop.get("name", ""))] = true

	var changed: Array[Dictionary] = []
	var unchanged: Array[String] = []
	var missing: Array[String] = []
	for key in values.keys():
		var property_name = str(key)
		if not known_names.has(property_name):
			missing.append(property_name)
			continue
		var expected = _encode_value(_decode_value(values[key]))
		var current = _encode_value(node.get(property_name))
		if current == expected:
			unchanged.append(property_name)
		else:
			changed.append(
				{
					"path": property_name,
					"current": current,
					"expected": expected,
				}
			)
	return _ok(
		{
			"node_path": str(node.get_path()),
			"changed_count": changed.size(),
			"unchanged_count": unchanged.size(),
			"missing_count": missing.size(),
			"changed": changed,
			"unchanged": unchanged,
			"missing": missing,
		}
	)

func _inspector_batch_apply(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var raw_node_paths = params.get("node_paths", [])
	if typeof(raw_node_paths) != TYPE_ARRAY or raw_node_paths.size() == 0:
		return _err(RPC_INVALID_PARAMS, "node_paths must be a non-empty array")
	var raw_patches = params.get("patches", [])
	if typeof(raw_patches) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "patches must be an array")

	var atomic = bool(params.get("atomic", true))
	var dry_run = bool(params.get("dry_run", true))
	var items: Array[Dictionary] = []
	var changed_count := 0
	var applied_count := 0
	var skipped_count := 0
	var validation_failed = false

	for raw_path in raw_node_paths:
		var node_path = str(raw_path)
		var node = _resolve_node(root, node_path)
		if node == null:
			validation_failed = true
			items.append({"node_path": node_path, "ok": false, "changed": false, "applied": 0, "error_count": 1, "errors": [{"error": "Node not found"}]})
			continue

		var preview = _inspector_preview_node_patches(node, raw_patches)
		var node_errors = preview.get("errors", [])
		var node_error_count = int(preview.get("error_count", 0))
		var node_changed = int(preview.get("would_change_count", 0))
		if node_error_count > 0:
			validation_failed = true
		if dry_run:
			items.append(
				{
					"node_path": str(node.get_path()),
					"ok": node_error_count == 0 or not atomic,
					"changed": node_changed > 0,
					"applied": 0,
					"would_change_count": node_changed,
					"error_count": node_error_count,
					"errors": node_errors,
				}
			)
			if node_changed == 0:
				skipped_count += 1
			continue

		if atomic and node_error_count > 0:
			items.append(
				{
					"node_path": str(node.get_path()),
					"ok": false,
					"changed": false,
					"applied": 0,
					"error_count": node_error_count,
					"errors": node_errors,
				}
			)
			skipped_count += 1
			continue

		var old_values: Dictionary = {}
		var node_applied := 0
		var preview_items = preview.get("items", [])
		if typeof(preview_items) == TYPE_ARRAY:
			for patch_preview in preview_items:
				if typeof(patch_preview) != TYPE_DICTIONARY:
					continue
				if not bool(patch_preview.get("ok", false)):
					continue
				if not bool(patch_preview.get("would_change", false)):
					continue
				var property_name = str(patch_preview.get("path", ""))
				old_values[property_name] = node.get(property_name)
				node.set(property_name, _decode_value(patch_preview.get("next", null)))
				node_applied += 1
		if node_applied > 0:
			changed_count += node_applied
			applied_count += 1
			_undo_register_node_properties(str(node.get_path()), old_values)
		else:
			skipped_count += 1
		items.append(
			{
				"node_path": str(node.get_path()),
				"ok": node_error_count == 0 or not atomic,
				"changed": node_applied > 0,
				"applied": node_applied,
				"error_count": node_error_count,
				"errors": node_errors,
			}
		)

	var payload = {
		"target_count": raw_node_paths.size(),
		"atomic": atomic,
		"dry_run": dry_run,
		"changed_count": changed_count,
		"applied_count": applied_count,
		"skipped_count": skipped_count,
		"items": items,
	}
	if not dry_run and atomic and validation_failed:
		return _err(RPC_INVALID_PARAMS, "Batch validation failed", payload)
	return _ok(payload)

func _inspector_preset_capture(params: Dictionary) -> Dictionary:
	var node_path = str(params.get("node_path", "."))
	var values_result = _inspector_values_get(
		{
			"node_path": node_path,
			"properties": params.get("properties", []),
			"include_private": bool(params.get("include_private", false)),
		}
	)
	if not values_result.get("ok", false):
		return values_result
	var data = values_result.get("data", {})
	var values = data.get("values", {})
	var serialized = JSON.stringify(values)
	var preset_id = str(abs(hash(serialized)))
	return _ok(
		{
			"node_path": str(data.get("node_path", node_path)),
			"preset_id": preset_id,
			"properties_count": int(data.get("count", 0)),
			"values": values,
		}
	)

func _inspector_preset_apply(params: Dictionary) -> Dictionary:
	var raw_preset = params.get("preset", {})
	if typeof(raw_preset) != TYPE_DICTIONARY:
		return _err(RPC_INVALID_PARAMS, "preset must be a dictionary")
	var values = raw_preset.get("values", raw_preset)
	if typeof(values) != TYPE_DICTIONARY or values.size() == 0:
		return _err(RPC_INVALID_PARAMS, "preset must contain non-empty values dictionary")
	var patches: Array[Dictionary] = []
	for key in values.keys():
		patches.append({"path": str(key), "value": values[key]})
	var serialized = JSON.stringify(values)
	var preset_id = str(abs(hash(serialized)))

	var apply_result = _inspector_batch_apply(
		{
			"node_paths": params.get("node_paths", []),
			"patches": patches,
			"atomic": bool(params.get("atomic", true)),
			"dry_run": bool(params.get("dry_run", true)),
		}
	)
	if apply_result.get("ok", false):
		var data = apply_result.get("data", {})
		data["preset_id"] = preset_id
		data["properties_count"] = values.size()
		apply_result["data"] = data
	return apply_result

func _node_call_method(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var method_name = str(params.get("method", ""))
	if method_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing method")
	var args: Array = params.get("args", [])
	if typeof(args) != TYPE_ARRAY:
		args = []
	for i in range(args.size()):
		args[i] = _decode_value(args[i])
	var result = node.callv(method_name, args)
	return _ok({"result": _encode_value(result)})

func _resource_load(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	var res = ResourceLoader.load(path)
	if res == null:
		return _err(RPC_INVALID_PARAMS, "Failed to load resource: %s" % path)
	return _ok({"path": path, "resource_type": res.get_class()})

func _resource_save(params: Dictionary) -> Dictionary:
	var source_norm = _guard.normalize_res_path(str(params.get("source_path", "")))
	var target_norm = _guard.normalize_res_path(str(params.get("target_path", "")))
	if not source_norm.get("ok", false) or not target_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, "Invalid source/target path")
	var source = str(source_norm.get("path", ""))
	var target = str(target_norm.get("path", ""))
	var res = ResourceLoader.load(source)
	if res == null:
		return _err(RPC_INVALID_PARAMS, "Failed to load source resource: %s" % source)
	var err = ResourceSaver.save(res, target)
	if err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save resource", {"error": err})
	return _ok({"saved": target})

func _resource_create(params: Dictionary) -> Dictionary:
	var resource_type = str(params.get("resource_type", "Resource"))
	if not ClassDB.can_instantiate(resource_type):
		return _err(RPC_INVALID_PARAMS, "Cannot instantiate resource type: %s" % resource_type)
	var instance = ClassDB.instantiate(resource_type)
	if not (instance is Resource):
		return _err(RPC_INVALID_PARAMS, "Type is not a Resource: %s" % resource_type)

	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	var err = ResourceSaver.save(instance, path)
	if err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save resource", {"error": err})
	return _ok({"created": path, "resource_type": resource_type})

func _resource_dependencies_graph(params: Dictionary) -> Dictionary:
	var root_path_input = str(params.get("root_path", "res://"))
	var root_norm = _guard.normalize_res_path(root_path_input)
	if not root_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(root_norm.get("error", "Invalid root_path")))
	var root_path = str(root_norm.get("path", "res://"))
	var max_depth = clamp(int(params.get("max_depth", 3)), 0, 16)

	var include_extensions: Array[String] = _to_string_array(params.get("include_extensions", [".tscn", ".scn", ".tres", ".res", ".material", ".shader", ".gdshader"]))
	if include_extensions.is_empty():
		include_extensions = [".tscn", ".scn", ".tres", ".res", ".material", ".shader", ".gdshader"]

	var start_paths: Array[String] = []
	if FileAccess.file_exists(root_path):
		start_paths.append(root_path)
	else:
		var entries: Array[Dictionary] = []
		_collect_dir_entries(root_path, true, true, false, entries)
		for entry in entries:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var file_path = str(entry.get("path", ""))
			if _path_has_any_extension(file_path, include_extensions):
				start_paths.append(file_path)

	var nodes: Dictionary = {}
	var edges: Array[Dictionary] = []
	var queue: Array[Dictionary] = []
	for start_path in start_paths:
		queue.append({"path": start_path, "depth": 0})
		nodes[start_path] = true

	while queue.size() > 0:
		var current = queue.pop_front()
		var current_path = str(current.get("path", ""))
		var depth = int(current.get("depth", 0))
		if current_path == "":
			continue
		if depth >= max_depth:
			continue
		var deps = ResourceLoader.get_dependencies(current_path)
		for dep_raw in deps:
			var dep_path = _extract_dependency_res_path(str(dep_raw))
			if dep_path == "":
				continue
			edges.append({"from": current_path, "to": dep_path})
			if not nodes.has(dep_path):
				nodes[dep_path] = true
			if depth + 1 <= max_depth and FileAccess.file_exists(dep_path):
				queue.append({"path": dep_path, "depth": depth + 1})

	var node_items: Array[String] = []
	for path_key in nodes.keys():
		node_items.append(str(path_key))
	node_items.sort()
	return _ok(
		{
			"root_path": root_path,
			"max_depth": max_depth,
			"node_count": node_items.size(),
			"edge_count": edges.size(),
			"nodes": node_items,
			"edges": edges,
		}
	)

func _resource_references_find(params: Dictionary) -> Dictionary:
	if not params.has("target_path"):
		return _err(RPC_INVALID_PARAMS, "Missing target_path")
	var target_norm = _guard.normalize_res_path(str(params.get("target_path", "")))
	if not target_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(target_norm.get("error", "Invalid target_path")))
	var target_path = str(target_norm.get("path", ""))

	var root_norm = _guard.normalize_res_path(str(params.get("root_path", "res://")))
	if not root_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(root_norm.get("error", "Invalid root_path")))
	var root_path = str(root_norm.get("path", "res://"))
	var max_results = clamp(int(params.get("max_results", 200)), 1, 5000)
	var include_extensions: Array[String] = _to_string_array(params.get("include_extensions", [".tscn", ".tres", ".res", ".gd", ".cfg", ".tscn", ".shader", ".gdshader"]))
	var files = _list_files_under(root_path, include_extensions)

	var items: Array[Dictionary] = []
	for file_path in files:
		if items.size() >= max_results:
			break
		var content = FileAccess.get_file_as_string(file_path)
		var index = content.find(target_path)
		if index == -1:
			continue
		items.append(
			{
				"path": file_path,
				"first_index": index,
				"line": _line_from_offset(content, index),
			}
		)

	return _ok({"target_path": target_path, "root_path": root_path, "count": items.size(), "items": items})

func _resource_replace_path(params: Dictionary) -> Dictionary:
	if not params.has("file_path") or not params.has("old_path") or not params.has("new_path"):
		return _err(RPC_INVALID_PARAMS, "Missing file_path/old_path/new_path")
	var file_norm = _guard.normalize_res_path(str(params.get("file_path", "")))
	var old_norm = _guard.normalize_res_path(str(params.get("old_path", "")))
	var new_norm = _guard.normalize_res_path(str(params.get("new_path", "")))
	if not file_norm.get("ok", false) or not old_norm.get("ok", false) or not new_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, "Invalid file_path/old_path/new_path")
	var file_path = str(file_norm.get("path", ""))
	var old_path = str(old_norm.get("path", ""))
	var new_path = str(new_norm.get("path", ""))
	if old_path == new_path:
		return _err(RPC_INVALID_PARAMS, "old_path and new_path cannot be the same")
	if not FileAccess.file_exists(file_path):
		return _err(RPC_INVALID_PARAMS, "File does not exist: %s" % file_path)

	var content = FileAccess.get_file_as_string(file_path)
	var occurrences = _count_occurrences(content, old_path)
	var dry_run = bool(params.get("dry_run", true))
	if not dry_run and occurrences > 0:
		_undo_capture_file_state(file_path)
		var replaced = content.replace(old_path, new_path)
		var write_result = _write_text_file(file_path, replaced)
		if not write_result.get("ok", false):
			return _err(ERR_EDITOR_BUSY, str(write_result.get("error", "Failed to write file")))
		if _undo_action_open and not _undo_replaying:
			_undo_change_count += 1

	return _ok(
		{
			"file_path": file_path,
			"old_path": old_path,
			"new_path": new_path,
			"dry_run": dry_run,
			"occurrences": occurrences,
			"updated": (occurrences > 0 and not dry_run),
		}
	)

func _resource_batch_replace_paths(params: Dictionary) -> Dictionary:
	var root_norm = _guard.normalize_res_path(str(params.get("root_path", "res://")))
	if not root_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(root_norm.get("error", "Invalid root_path")))
	var root_path = str(root_norm.get("path", "res://"))
	var raw_replacements = params.get("replacements", [])
	if typeof(raw_replacements) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "replacements must be an array")
	var dry_run = bool(params.get("dry_run", true))
	var include_extensions: Array[String] = _to_string_array(params.get("include_extensions", [".tscn", ".tres", ".res", ".gd", ".cfg", ".shader", ".gdshader"]))
	var files = _list_files_under(root_path, include_extensions)

	var replacements: Array[Dictionary] = []
	for item in raw_replacements:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var old_norm = _guard.normalize_res_path(str(item.get("old_path", "")))
		var new_norm = _guard.normalize_res_path(str(item.get("new_path", "")))
		if not old_norm.get("ok", false) or not new_norm.get("ok", false):
			continue
		var old_path = str(old_norm.get("path", ""))
		var new_path = str(new_norm.get("path", ""))
		if old_path == "" or new_path == "" or old_path == new_path:
			continue
		replacements.append({"old_path": old_path, "new_path": new_path})

	var changed_files := 0
	var total_replacements := 0
	var item_results: Array[Dictionary] = []
	for file_path in files:
		var original = FileAccess.get_file_as_string(file_path)
		var updated = original
		var file_replacements := 0
		for replacement in replacements:
			var old_path = str(replacement.get("old_path", ""))
			var new_path = str(replacement.get("new_path", ""))
			var count = _count_occurrences(updated, old_path)
			if count > 0:
				file_replacements += count
				updated = updated.replace(old_path, new_path)
		if file_replacements == 0:
			continue
		changed_files += 1
		total_replacements += file_replacements
		if not dry_run:
			_undo_capture_file_state(file_path)
			var write_result = _write_text_file(file_path, updated)
			if not write_result.get("ok", false):
				item_results.append({"path": file_path, "ok": false, "error": str(write_result.get("error", "Failed to write file"))})
				continue
			if _undo_action_open and not _undo_replaying:
				_undo_change_count += 1
		item_results.append({"path": file_path, "ok": true, "replacements": file_replacements, "applied": not dry_run})

	return _ok(
		{
			"root_path": root_path,
			"dry_run": dry_run,
			"replacement_count": replacements.size(),
			"file_count": files.size(),
			"changed_files": changed_files,
			"total_replacements": total_replacements,
			"items": item_results,
		}
	)

func _resource_orphans_find(params: Dictionary) -> Dictionary:
	var root_norm = _guard.normalize_res_path(str(params.get("root_path", "res://")))
	if not root_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(root_norm.get("error", "Invalid root_path")))
	var root_path = str(root_norm.get("path", "res://"))
	var include_extensions: Array[String] = _to_string_array(params.get("include_extensions", [".tscn", ".scn", ".tres", ".res", ".gd", ".shader", ".gdshader", ".png", ".jpg", ".jpeg", ".wav", ".ogg", ".mp3"]))
	var text_extensions: Array[String] = _to_string_array(params.get("text_extensions", [".tscn", ".scn", ".tres", ".res", ".gd", ".cfg", ".shader", ".gdshader", ".import"]))

	var candidates = _list_files_under(root_path, include_extensions)
	var text_files = _list_files_under(root_path, text_extensions)
	var referenced: Dictionary = {}
	for file_path in text_files:
		var content = FileAccess.get_file_as_string(file_path)
		for found_path in _extract_res_paths_from_text(content):
			referenced[found_path] = true

	var orphans: Array[String] = []
	for candidate in candidates:
		if not referenced.has(candidate):
			orphans.append(candidate)
	orphans.sort()
	var max_results = clamp(int(params.get("max_results", 1000)), 1, 10000)
	if orphans.size() > max_results:
		orphans = orphans.slice(0, max_results)
	return _ok({"root_path": root_path, "count": orphans.size(), "items": orphans})

func _resource_duplicate(params: Dictionary) -> Dictionary:
	var source_norm = _guard.normalize_res_path(str(params.get("source_path", "")))
	var target_norm = _guard.normalize_res_path(str(params.get("target_path", "")))
	if not source_norm.get("ok", false) or not target_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, "Invalid source_path/target_path")
	var source_path = str(source_norm.get("path", ""))
	var target_path = str(target_norm.get("path", ""))
	if source_path == target_path:
		return _err(RPC_INVALID_PARAMS, "source_path and target_path cannot be the same")
	var overwrite = bool(params.get("overwrite", false))
	var dry_run = bool(params.get("dry_run", true))
	if not FileAccess.file_exists(source_path):
		return _err(RPC_INVALID_PARAMS, "Source does not exist: %s" % source_path)
	if FileAccess.file_exists(target_path) and not overwrite:
		return _err(RPC_INVALID_PARAMS, "Target exists and overwrite=false")
	if dry_run:
		return _ok({"source_path": source_path, "target_path": target_path, "dry_run": true, "duplicated": false})

	var res = ResourceLoader.load(source_path)
	if res != null:
		var save_err = ResourceSaver.save(res, target_path)
		if save_err != OK:
			return _err(ERR_EDITOR_BUSY, "Failed to duplicate resource", {"error": save_err})
	else:
		var content = FileAccess.get_file_as_string(source_path)
		var write_result = _write_text_file(target_path, content)
		if not write_result.get("ok", false):
			return _err(ERR_EDITOR_BUSY, str(write_result.get("error", "Failed to duplicate file")))
	_undo_capture_file_state(target_path)
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"source_path": source_path, "target_path": target_path, "dry_run": false, "duplicated": true})

func _resource_move(params: Dictionary) -> Dictionary:
	var source_norm = _guard.normalize_res_path(str(params.get("source_path", "")))
	var target_norm = _guard.normalize_res_path(str(params.get("target_path", "")))
	if not source_norm.get("ok", false) or not target_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, "Invalid source_path/target_path")
	var source_path = str(source_norm.get("path", ""))
	var target_path = str(target_norm.get("path", ""))
	if source_path == target_path:
		return _err(RPC_INVALID_PARAMS, "source_path and target_path cannot be the same")
	var overwrite = bool(params.get("overwrite", false))
	var dry_run = bool(params.get("dry_run", true))
	if not FileAccess.file_exists(source_path):
		return _err(RPC_INVALID_PARAMS, "Source does not exist: %s" % source_path)
	if FileAccess.file_exists(target_path) and not overwrite:
		return _err(RPC_INVALID_PARAMS, "Target exists and overwrite=false")
	if dry_run:
		return _ok({"source_path": source_path, "target_path": target_path, "dry_run": true, "moved": false})

	var target_dir = ProjectSettings.globalize_path(target_path).get_base_dir()
	var mk_err = DirAccess.make_dir_recursive_absolute(target_dir)
	if mk_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to create target directory", {"error": mk_err})
	if FileAccess.file_exists(target_path) and overwrite:
		var remove_err = _delete_res_file(target_path)
		if remove_err != OK and remove_err != ERR_FILE_NOT_FOUND:
			return _err(ERR_EDITOR_BUSY, "Failed to overwrite target", {"error": remove_err})

	_undo_capture_file_state(source_path)
	_undo_capture_file_state(target_path)
	var move_err = DirAccess.rename_absolute(ProjectSettings.globalize_path(source_path), ProjectSettings.globalize_path(target_path))
	if move_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to move resource", {"error": move_err})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"source_path": source_path, "target_path": target_path, "dry_run": false, "moved": true})

func _resource_rename(params: Dictionary) -> Dictionary:
	var source_norm = _guard.normalize_res_path(str(params.get("source_path", "")))
	if not source_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(source_norm.get("error", "Invalid source_path")))
	var source_path = str(source_norm.get("path", ""))
	var new_name = str(params.get("new_name", "")).strip_edges()
	if new_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing new_name")
	if new_name.find("/") != -1 or new_name.find("\\") != -1:
		return _err(RPC_INVALID_PARAMS, "new_name cannot contain path separators")
	var target_path = source_path.get_base_dir().path_join(new_name)
	return _resource_move(
		{
			"source_path": source_path,
			"target_path": target_path,
			"overwrite": bool(params.get("overwrite", false)),
			"dry_run": bool(params.get("dry_run", true)),
		}
	)

func _script_create(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not path.ends_with(".gd"):
		return _err(RPC_INVALID_PARAMS, "Script path must end with .gd")

	var template = str(params.get("template", "node"))
	var script_class = str(params.get("class_name", "GeneratedScript"))
	var content = _render_script_template(template, script_class)
	var write_result = _write_text_file(path, content)
	if not write_result.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(write_result.get("error", "Failed to write script")))
	return _ok({"created": path})

func _script_attach(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")
	var node = _resolve_node(root, str(params.get("node_path", "")))
	if node == null:
		return _err(RPC_INVALID_PARAMS, "Node not found")
	var normalized = _guard.normalize_res_path(str(params.get("script_path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var script_path = str(normalized.get("path", ""))
	var script_res = ResourceLoader.load(script_path)
	if script_res == null:
		return _err(RPC_INVALID_PARAMS, "Failed to load script: %s" % script_path)
	node.set_script(script_res)
	return _ok({"node_path": str(node.get_path()), "script_path": script_path})

func _script_get_text(params: Dictionary) -> Dictionary:
	return _filesystem_read_text({"path": params.get("path", "")})

func _script_set_text(params: Dictionary) -> Dictionary:
	var path = str(params.get("path", ""))
	var content = str(params.get("content", ""))
	return _filesystem_write_text({
		"path": path,
		"content": content,
		"overwrite": true,
	})

func _script_ast_find_symbols(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "File does not exist: %s" % path)

	var content = FileAccess.get_file_as_string(path)
	var lines = content.split("\n")
	var symbols: Array[Dictionary] = []
	var class_re = RegEx.new()
	class_re.compile("^\\s*class_name\\s+([A-Za-z_][A-Za-z0-9_]*)")
	var func_re = RegEx.new()
	func_re.compile("^\\s*(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)")
	var var_re = RegEx.new()
	var_re.compile("^\\s*(?:@export\\s+)?var\\s+([A-Za-z_][A-Za-z0-9_]*)")
	var signal_re = RegEx.new()
	signal_re.compile("^\\s*signal\\s+([A-Za-z_][A-Za-z0-9_]*)")

	for i in range(lines.size()):
		var line_text = str(lines[i])
		var class_match = class_re.search(line_text)
		if class_match != null:
			symbols.append({"type": "class_name", "name": class_match.get_string(1), "line": i + 1})
		var func_match = func_re.search(line_text)
		if func_match != null:
			symbols.append({"type": "function", "name": func_match.get_string(1), "line": i + 1})
		var var_match = var_re.search(line_text)
		if var_match != null:
			symbols.append({"type": "variable", "name": var_match.get_string(1), "line": i + 1})
		var signal_match = signal_re.search(line_text)
		if signal_match != null:
			symbols.append({"type": "signal", "name": signal_match.get_string(1), "line": i + 1})

	return _ok({"path": path, "count": symbols.size(), "symbols": symbols})

func _script_refactor_rename_symbol(params: Dictionary) -> Dictionary:
	var old_name = str(params.get("old_name", "")).strip_edges()
	var new_name = str(params.get("new_name", "")).strip_edges()
	if old_name == "" or new_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing old_name/new_name")
	if old_name == new_name:
		return _err(RPC_INVALID_PARAMS, "old_name and new_name cannot be the same")
	var dry_run = bool(params.get("dry_run", true))
	var whole_word = bool(params.get("whole_word", true))
	var root_norm = _guard.normalize_res_path(str(params.get("root_path", "res://")))
	if not root_norm.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(root_norm.get("error", "Invalid root_path")))
	var root_path = str(root_norm.get("path", "res://"))
	var max_files = clamp(int(params.get("max_files", 500)), 1, 5000)

	var files: Array[String] = []
	var raw_paths = params.get("paths", [])
	if typeof(raw_paths) == TYPE_ARRAY and raw_paths.size() > 0:
		for item in raw_paths:
			var normalized = _guard.normalize_res_path(str(item))
			if normalized.get("ok", false):
				var path = str(normalized.get("path", ""))
				if path.ends_with(".gd") and FileAccess.file_exists(path):
					files.append(path)
	else:
		files = _list_files_under(root_path, [".gd"])
	if files.size() > max_files:
		files = files.slice(0, max_files)

	var pattern = old_name
	if whole_word:
		pattern = "(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % _regex_escape_literal(old_name)
	var rename_regex = RegEx.new()
	var compile_err = rename_regex.compile(pattern)
	if compile_err != OK:
		return _err(RPC_INVALID_PARAMS, "Invalid symbol pattern")

	var changed_files := 0
	var total_replacements := 0
	var items: Array[Dictionary] = []
	for path in files:
		var content = FileAccess.get_file_as_string(path)
		var matches = rename_regex.search_all(content)
		if matches.size() == 0:
			continue
		var replaced_content = rename_regex.sub(content, new_name, true)
		var replacement_count = matches.size()
		changed_files += 1
		total_replacements += replacement_count
		if not dry_run:
			_undo_capture_file_state(path)
			var write_result = _write_text_file(path, replaced_content)
			if not write_result.get("ok", false):
				items.append({"path": path, "ok": false, "error": str(write_result.get("error", "Failed to write file"))})
				continue
			if _undo_action_open and not _undo_replaying:
				_undo_change_count += 1
		items.append({"path": path, "ok": true, "replacements": replacement_count, "applied": not dry_run})

	return _ok(
		{
			"root_path": root_path,
			"old_name": old_name,
			"new_name": new_name,
			"dry_run": dry_run,
			"changed_files": changed_files,
			"total_replacements": total_replacements,
			"items": items,
		}
	)

func _script_refactor_add_method_stub(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "File does not exist: %s" % path)
	var method_name = str(params.get("method_name", "")).strip_edges()
	if method_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing method_name")

	var content = FileAccess.get_file_as_string(path)
	var exists_re = RegEx.new()
	exists_re.compile("^\\s*(?:static\\s+)?func\\s+%s\\s*\\(" % _regex_escape_literal(method_name))
	for line in content.split("\n"):
		if exists_re.search(line) != null:
			return _ok({"path": path, "method_name": method_name, "added": false, "reason": "already_exists"})

	var args = params.get("args", [])
	var arg_names: Array[String] = []
	if typeof(args) == TYPE_ARRAY:
		for item in args:
			arg_names.append(str(item))
	var return_type = str(params.get("return_type", "")).strip_edges()
	var body_lines = params.get("body_lines", ["pass"])
	var stub_lines: Array[String] = []
	stub_lines.append("")
	var signature = "func %s(%s)" % [method_name, ", ".join(arg_names)]
	if return_type != "":
		signature += " -> %s" % return_type
	signature += ":"
	stub_lines.append(signature)
	if typeof(body_lines) == TYPE_ARRAY and body_lines.size() > 0:
		for body_line in body_lines:
			stub_lines.append("\t%s" % str(body_line))
	else:
		stub_lines.append("\tpass")
	var updated = content
	if not updated.ends_with("\n"):
		updated += "\n"
	updated += "\n".join(stub_lines) + "\n"
	_undo_capture_file_state(path)
	var write_result = _write_text_file(path, updated)
	if not write_result.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(write_result.get("error", "Failed to write script")))
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"path": path, "method_name": method_name, "added": true})

func _script_refactor_organize_regions(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "File does not exist: %s" % path)

	var dry_run = bool(params.get("dry_run", true))
	var content = FileAccess.get_file_as_string(path)
	var organized = _organize_gdscript_methods(content)
	if dry_run:
		return _ok({"path": path, "dry_run": true, "changed": organized != content})
	if organized == content:
		return _ok({"path": path, "dry_run": false, "changed": false, "applied": false})

	_undo_capture_file_state(path)
	var write_result = _write_text_file(path, organized)
	if not write_result.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(write_result.get("error", "Failed to write script")))
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"path": path, "dry_run": false, "changed": true, "applied": true})

func _project_play() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface.has_method("play_main_scene"):
		iface.call("play_main_scene")
		return _ok({"playing": true})
	_state.record_warning("project.play is not supported in this Godot build")
	return _ok({"playing": false, "warning": "Not supported by this Godot build"})

func _project_stop() -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface.has_method("stop_playing_scene"):
		iface.call("stop_playing_scene")
		return _ok({"playing": false})
	_state.record_warning("project.stop is not supported in this Godot build")
	return _ok({"playing": false, "warning": "Not supported by this Godot build"})

func _project_reload() -> Dictionary:
	if _plugin != null and _plugin.has_method("request_project_reload"):
		var response = _plugin.call("request_project_reload")
		if typeof(response) == TYPE_DICTIONARY:
			return _ok(response)
		return _ok({"scheduled": true})
	return _err(ERR_EDITOR_BUSY, "project.reload is not available")

func _project_get_main_scene() -> Dictionary:
	var main_scene = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	return _ok({"main_scene": main_scene})

func _project_set_main_scene(params: Dictionary) -> Dictionary:
	if not params.has("path"):
		return _err(RPC_INVALID_PARAMS, "Missing path")

	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "Scene does not exist: %s" % path)

	ProjectSettings.set_setting("application/run/main_scene", path)
	var save_err = ProjectSettings.save()
	if save_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save project settings", {"error": save_err})
	return _ok({"main_scene": path})

func _project_inputmap_list(_params: Dictionary) -> Dictionary:
	var items: Array[Dictionary] = []
	for action_name_item in InputMap.get_actions():
		var action_name = str(action_name_item)
		if action_name == "":
			continue
		var events_payload: Array[Dictionary] = []
		for event in InputMap.action_get_events(action_name):
			if event is InputEvent:
				events_payload.append(_serialize_input_event(event))
		items.append(
			{
				"action": action_name,
				"deadzone": float(InputMap.action_get_deadzone(action_name)),
				"event_count": events_payload.size(),
				"events": events_payload,
			}
		)
	return _ok({"count": items.size(), "items": items})

func _project_inputmap_set(params: Dictionary) -> Dictionary:
	var action_name = str(params.get("action", "")).strip_edges()
	if action_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing action")

	var deadzone = float(params.get("deadzone", 0.5))
	deadzone = clampf(deadzone, 0.0, 1.0)
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name, deadzone)
	else:
		InputMap.action_set_deadzone(action_name, deadzone)

	var replace = bool(params.get("replace", true))
	if replace:
		for existing_event in InputMap.action_get_events(action_name):
			if existing_event is InputEvent:
				InputMap.action_erase_event(action_name, existing_event)

	var raw_events = params.get("events", [])
	if typeof(raw_events) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "events must be an array")
	var applied: Array[Dictionary] = []
	var skipped: Array[Dictionary] = []
	for event_item in raw_events:
		if typeof(event_item) != TYPE_DICTIONARY:
			skipped.append({"ok": false, "error": "event spec must be a dictionary"})
			continue
		var event_obj = _deserialize_input_event(event_item)
		if not (event_obj is InputEvent):
			skipped.append({"ok": false, "error": "Unsupported input event type", "spec": event_item})
			continue
		InputMap.action_add_event(action_name, event_obj)
		applied.append(_serialize_input_event(event_obj))

	var sync_err = _sync_input_action_to_project_settings(action_name)
	if sync_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to persist input action", {"error": sync_err, "action": action_name})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"action": action_name,
			"deadzone": float(InputMap.action_get_deadzone(action_name)),
			"replace": replace,
			"added_count": applied.size(),
			"skipped_count": skipped.size(),
			"events": applied,
			"skipped": skipped,
		}
	)

func _project_inputmap_erase(params: Dictionary) -> Dictionary:
	var action_name = str(params.get("action", "")).strip_edges()
	if action_name == "":
		return _err(RPC_INVALID_PARAMS, "Missing action")
	var ignore_missing = bool(params.get("ignore_missing", true))
	if not InputMap.has_action(action_name):
		if ignore_missing:
			return _ok({"action": action_name, "removed": false, "missing": true})
		return _err(RPC_INVALID_PARAMS, "Input action does not exist: %s" % action_name)

	InputMap.erase_action(action_name)
	var sync_err = _sync_input_action_to_project_settings(action_name)
	if sync_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to persist input action removal", {"error": sync_err, "action": action_name})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"action": action_name, "removed": true, "missing": false})

func _project_autoload_list() -> Dictionary:
	var items: Array[Dictionary] = []
	for entry in ProjectSettings.get_property_list():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var property_name = str(entry.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var name = property_name.trim_prefix("autoload/")
		var raw_value = str(ProjectSettings.get_setting(property_name, ""))
		var singleton = raw_value.begins_with("*")
		var path = raw_value
		if singleton:
			path = raw_value.trim_prefix("*")
		items.append(
			{
				"name": name,
				"path": path,
				"singleton": singleton,
				"value": raw_value,
			}
		)
	return _ok({"count": items.size(), "items": items})

func _project_autoload_add(params: Dictionary) -> Dictionary:
	var name = str(params.get("name", "")).strip_edges()
	if name == "":
		return _err(RPC_INVALID_PARAMS, "Missing name")
	if name.find("/") != -1:
		return _err(RPC_INVALID_PARAMS, "Autoload name cannot contain '/'")
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "Autoload path does not exist: %s" % path)

	var singleton = bool(params.get("singleton", true))
	var overwrite = bool(params.get("overwrite", false))
	var key = "autoload/%s" % name
	var existed = ProjectSettings.has_setting(key)
	if existed and not overwrite:
		return _err(RPC_INVALID_PARAMS, "Autoload already exists: %s" % name)

	var stored_value = path
	if singleton:
		stored_value = "*" + path
	ProjectSettings.set_setting(key, stored_value)
	var save_err = ProjectSettings.save()
	if save_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save project settings", {"error": save_err})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok(
		{
			"name": name,
			"path": path,
			"singleton": singleton,
			"added": true,
			"overwritten": existed,
			"requires_reload": true,
		}
	)

func _project_autoload_remove(params: Dictionary) -> Dictionary:
	var name = str(params.get("name", "")).strip_edges()
	if name == "":
		return _err(RPC_INVALID_PARAMS, "Missing name")
	var ignore_missing = bool(params.get("ignore_missing", true))
	var key = "autoload/%s" % name
	var existed = ProjectSettings.has_setting(key)
	if not existed:
		if ignore_missing:
			return _ok({"name": name, "removed": false, "missing": true, "requires_reload": true})
		return _err(RPC_INVALID_PARAMS, "Autoload does not exist: %s" % name)

	if ProjectSettings.has_method("clear"):
		ProjectSettings.call("clear", key)
	else:
		ProjectSettings.set_setting(key, null)
	var save_err = ProjectSettings.save()
	if save_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save project settings", {"error": save_err})
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1
	return _ok({"name": name, "removed": true, "missing": false, "requires_reload": true})

func _project_build(params: Dictionary) -> Dictionary:
	var requested_backend := str(params.get("backend", "auto")).to_lower()
	if not ["auto", "dotnet", "export", "command"].has(requested_backend):
		return _err(RPC_INVALID_PARAMS, "Unsupported build backend: %s" % requested_backend)

	var dry_run := bool(params.get("dry_run", false))
	var prepared = _project_prepare_build(requested_backend, params)
	if not prepared.get("ok", false):
		var fail_code = int(prepared.get("code", ERR_EDITOR_BUSY))
		var reason = str(prepared.get("reason", "No supported build backend found"))
		var fail_data = {
			"backend": requested_backend,
			"details": prepared.get("details", []),
		}
		if fail_code == ERR_EDITOR_BUSY:
			_state.record_warning("project.build unavailable: %s" % reason)
		return _err(fail_code, reason, fail_data)

	var resolved_backend = str(prepared.get("backend", requested_backend))
	var command = str(prepared.get("command", ""))
	var args: PackedStringArray = _to_packed_string_array(prepared.get("args", PackedStringArray()))
	var command_line: Array[String] = [command]
	for arg in args:
		command_line.append(str(arg))

	var result_data = {
		"started": false,
		"backend": requested_backend,
		"resolved_backend": resolved_backend,
		"pid": -1,
		"command_line": command_line,
		"dry_run": dry_run,
	}
	if prepared.has("target"):
		result_data["target"] = str(prepared.get("target", ""))
	if prepared.has("output_path"):
		result_data["output_path"] = str(prepared.get("output_path", ""))

	if dry_run:
		result_data["reason"] = "dry_run"
		return _ok(result_data)

	var pid = OS.create_process(command, args, false)
	if pid <= 0:
		result_data["reason"] = "Failed to start build process"
		return _err(ERR_EDITOR_BUSY, "Failed to start build process", result_data)

	result_data["started"] = true
	result_data["pid"] = pid
	return _ok(result_data)

func _project_prepare_build(requested_backend: String, params: Dictionary) -> Dictionary:
	var configuration = str(params.get("configuration", "")).strip_edges()
	var target = str(params.get("target", "")).strip_edges()
	var command = str(params.get("command", "")).strip_edges()

	match requested_backend:
		"dotnet":
			return _project_prepare_dotnet(configuration)
		"export":
			return _project_prepare_export(target, configuration)
		"command":
			return _project_prepare_command(params)
		"auto":
			var reasons: Array[String] = []
			var dotnet = _project_prepare_dotnet(configuration)
			if dotnet.get("ok", false):
				return dotnet
			reasons.append(str(dotnet.get("reason", "dotnet unavailable")))

			var export = _project_prepare_export(target, configuration)
			if export.get("ok", false):
				return export
			reasons.append(str(export.get("reason", "export unavailable")))

			if command != "":
				var custom = _project_prepare_command(params)
				if custom.get("ok", false):
					return custom
				reasons.append(str(custom.get("reason", "command backend unavailable")))

			return {
				"ok": false,
				"code": ERR_EDITOR_BUSY,
				"reason": "No supported build backend found for backend=auto",
				"details": reasons,
			}
		_:
			return {"ok": false, "code": RPC_INVALID_PARAMS, "reason": "Unsupported build backend: %s" % requested_backend}

func _project_prepare_dotnet(configuration: String) -> Dictionary:
	var csproj_path := "res://Assembly-CSharp.csproj"
	if not FileAccess.file_exists(csproj_path):
		return {"ok": false, "code": ERR_EDITOR_BUSY, "reason": "Assembly-CSharp.csproj not found"}

	var args: PackedStringArray = [
		"build",
		ProjectSettings.globalize_path(csproj_path),
		"-v",
		"minimal",
	]
	if configuration != "":
		args.append("-c")
		args.append(configuration)
	return {"ok": true, "backend": "dotnet", "command": "dotnet", "args": args}

func _project_prepare_export(target: String, configuration: String) -> Dictionary:
	var export_presets_path := "res://export_presets.cfg"
	if not FileAccess.file_exists(export_presets_path):
		return {"ok": false, "code": ERR_EDITOR_BUSY, "reason": "export_presets.cfg not found"}

	var preset_name := target
	if preset_name == "":
		preset_name = _project_first_export_preset_name()
	if preset_name == "":
		return {"ok": false, "code": ERR_EDITOR_BUSY, "reason": "No export preset name available"}

	var exe_path := OS.get_executable_path()
	if exe_path == "":
		return {"ok": false, "code": ERR_EDITOR_BUSY, "reason": "Godot executable path is unavailable"}

	var mode := "release"
	var cfg_lower = configuration.to_lower()
	if cfg_lower.find("debug") != -1:
		mode = "debug"

	var safe_preset = preset_name.replace(" ", "_").replace("/", "_").replace("\\", "_")
	var output_res = "res://.godot_mcp_tmp/builds/%s_%s.bin" % [safe_preset, mode]
	var output_abs = ProjectSettings.globalize_path(output_res)
	var mk_err = DirAccess.make_dir_recursive_absolute(output_abs.get_base_dir())
	if mk_err != OK:
		return {"ok": false, "code": ERR_EDITOR_BUSY, "reason": "Failed to create export output directory", "error": mk_err}

	var args: PackedStringArray = [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
	]
	if mode == "debug":
		args.append("--export-debug")
	else:
		args.append("--export-release")
	args.append(preset_name)
	args.append(output_abs)
	return {
		"ok": true,
		"backend": "export",
		"command": exe_path,
		"args": args,
		"target": preset_name,
		"output_path": output_res,
	}

func _project_prepare_command(params: Dictionary) -> Dictionary:
	var command = str(params.get("command", "")).strip_edges()
	if command == "":
		return {"ok": false, "code": RPC_INVALID_PARAMS, "reason": "backend=command requires non-empty command"}

	var args_variant = params.get("args", [])
	if typeof(args_variant) != TYPE_ARRAY:
		return {"ok": false, "code": RPC_INVALID_PARAMS, "reason": "args must be an array of strings"}
	var args: PackedStringArray = []
	for item in args_variant:
		args.append(str(item))
	return {"ok": true, "backend": "command", "command": command, "args": args}

func _project_first_export_preset_name() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://export_presets.cfg")
	if err != OK:
		return ""
	for section in cfg.get_sections():
		var section_name = str(section)
		if section_name.begins_with("preset."):
			var preset_name = str(cfg.get_value(section_name, "name", ""))
			if preset_name != "":
				return preset_name
	return ""

func _to_packed_string_array(value: Variant) -> PackedStringArray:
	var out: PackedStringArray = []
	if typeof(value) == TYPE_PACKED_STRING_ARRAY:
		return value
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			out.append(str(item))
	return out

func _diagnostics_get_errors(params: Dictionary) -> Dictionary:
	var limit = int(params.get("limit", 50))
	limit = clamp(limit, 1, 200)
	return _ok({"items": _state.get_errors(limit)})

func _diagnostics_get_warnings(params: Dictionary) -> Dictionary:
	var limit = int(params.get("limit", 50))
	limit = clamp(limit, 1, 200)
	return _ok({"items": _state.get_warnings(limit)})

func _screenshot_capture_editor(params: Dictionary) -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface == null:
		return _err(ERR_EDITOR_BUSY, "Editor interface is not available")
	var base_control = iface.get_base_control()
	if base_control == null:
		return _err(ERR_EDITOR_BUSY, "Editor base control is not available")
	var viewport = base_control.get_viewport()
	return _screenshot_capture_from_viewport(viewport, "editor", params)

func _screenshot_capture_game(params: Dictionary) -> Dictionary:
	var iface = _plugin.get_editor_interface()
	if iface == null:
		return _err(ERR_EDITOR_BUSY, "Editor interface is not available")
	if iface.has_method("is_playing_scene") and not bool(iface.call("is_playing_scene")):
		return _err(ERR_SCENE_CONTEXT, "Game is not running. Start play mode before capturing game screenshot.")
	var tree = _plugin.get_tree()
	if tree == null or tree.root == null:
		return _err(ERR_EDITOR_BUSY, "SceneTree root viewport is not available")
	return _screenshot_capture_from_viewport(tree.root, "game", params)

func _runtime_logs_tail(params: Dictionary) -> Dictionary:
	var limit = clamp(int(params.get("limit", 200)), 1, 2000)
	var level = _normalize_runtime_log_level(str(params.get("level", "all")))
	if level == "":
		return _err(RPC_INVALID_PARAMS, "Invalid level. Use one of: all,error,warning,info")
	var source_file = _runtime_latest_log_path()
	if source_file == "":
		return _ok({"source_file": "", "level": level, "line_count": 0, "items": []})
	if not FileAccess.file_exists(source_file):
		return _ok({"source_file": source_file, "level": level, "line_count": 0, "items": []})

	var content = FileAccess.get_file_as_string(source_file)
	var lines = content.split("\n")
	var items: Array[Dictionary] = []
	for i in range(lines.size() - 1, -1, -1):
		var raw = str(lines[i]).strip_edges()
		if raw == "":
			continue
		var item = _parse_runtime_log_line(raw)
		var item_level = str(item.get("level", "info"))
		if level != "all" and item_level != level:
			continue
		items.append(item)
		if items.size() >= limit:
			break
	items.reverse()
	return _ok(
		{
			"source_file": source_file,
			"level": level,
			"line_count": items.size(),
			"items": items,
		}
	)

func _runtime_logs_stream(params: Dictionary) -> Dictionary:
	var limit = clamp(int(params.get("limit", 200)), 1, 2000)
	var level = _normalize_runtime_log_level(str(params.get("level", "all")))
	if level == "":
		return _err(RPC_INVALID_PARAMS, "Invalid level. Use one of: all,error,warning,info")
	var source_file = _runtime_latest_log_path()
	if source_file == "":
		return _ok({"source_file": "", "level": level, "cursor": 0, "line_count": 0, "has_more": false, "items": []})
	if not FileAccess.file_exists(source_file):
		return _ok(
			{
				"source_file": source_file,
				"level": level,
				"cursor": 0,
				"line_count": 0,
				"has_more": false,
				"items": [],
			}
		)

	var previous_source_file = str(params.get("source_file", ""))
	var source_changed = previous_source_file != "" and previous_source_file != source_file
	var cursor = maxi(0, int(params.get("cursor", 0)))
	if source_changed:
		cursor = 0

	var content = FileAccess.get_file_as_string(source_file)
	var lines = content.split("\n")
	var total_lines = lines.size()
	if cursor > total_lines:
		cursor = 0

	var items: Array[Dictionary] = []
	var has_more := false
	for i in range(cursor, total_lines):
		var raw = str(lines[i]).strip_edges()
		if raw == "":
			continue
		var item = _parse_runtime_log_line(raw)
		var item_level = str(item.get("level", "info"))
		if level != "all" and item_level != level:
			continue
		items.append(item)
		if items.size() > limit:
			has_more = true
			items.pop_front()
	return _ok(
		{
			"source_file": source_file,
			"level": level,
			"source_changed": source_changed,
			"cursor": total_lines,
			"from_cursor": cursor,
			"line_count": items.size(),
			"has_more": has_more,
			"items": items,
		}
	)

func _runtime_logs_parse_errors(params: Dictionary) -> Dictionary:
	var limit = clamp(int(params.get("limit", 100)), 1, 1000)
	var source_file = _runtime_latest_log_path()
	if source_file == "" or not FileAccess.file_exists(source_file):
		return _ok({"source_file": source_file, "count": 0, "items": []})

	var content = FileAccess.get_file_as_string(source_file)
	var lines = content.split("\n")
	var file_line_re = RegEx.new()
	file_line_re.compile("(res://[^:\\s\\)]+):(\\d+)")
	var items: Array[Dictionary] = []
	for i in range(lines.size() - 1, -1, -1):
		var raw = str(lines[i]).strip_edges()
		if raw == "":
			continue
		var error_type = _runtime_error_type(raw)
		if error_type == "":
			continue
		var item = {
			"type": error_type,
			"message": raw,
			"raw": raw,
		}
		var file_match = file_line_re.search(raw)
		if file_match != null:
			item["file"] = file_match.get_string(1)
			item["line"] = int(file_match.get_string(2))
		items.append(item)
		if items.size() >= limit:
			break
	items.reverse()
	return _ok({"source_file": source_file, "count": items.size(), "items": items})

func _runtime_debugger_snapshot(params: Dictionary) -> Dictionary:
	var limit = clamp(int(params.get("limit", 120)), 1, 2000)
	var summary = _runtime_collect_error_summary(limit)
	var iface = _plugin.get_editor_interface()
	var playing_scene := false
	if iface != null and iface.has_method("is_playing_scene"):
		playing_scene = bool(iface.call("is_playing_scene"))
	var session = _state.snapshot()
	var root = _current_root()
	return _ok(
		{
			"is_playing_scene": playing_scene,
			"edited_scene_root_path": "" if root == null else str(root.get_path()),
			"edited_scene_file_path": "" if root == null else str(root.scene_file_path),
			"runtime": summary,
			"bridge_errors": _state.get_errors(clamp(limit, 1, 200)),
			"bridge_warnings": _state.get_warnings(clamp(limit, 1, 200)),
			"session": session,
		}
	)

func _runtime_errors_delta(params: Dictionary) -> Dictionary:
	var baseline_name = str(params.get("baseline", "default")).strip_edges()
	if baseline_name == "":
		baseline_name = "default"
	var reset = bool(params.get("reset", false))
	var update_baseline = bool(params.get("update_baseline", true))
	var limit = clamp(int(params.get("limit", 200)), 1, 2000)
	var current = _runtime_collect_error_summary(limit).get("counts", {})
	var previous = _state.get_runtime_error_baseline(baseline_name)
	var has_previous = not previous.is_empty() and not reset
	var delta = {}
	var keys = [
		"runtime_log_errors",
		"runtime_log_warnings",
		"parse_errors",
		"bridge_errors",
		"bridge_warnings",
	]
	for key in keys:
		var current_value = int(current.get(key, 0))
		var previous_value = 0
		if has_previous:
			previous_value = int(previous.get(key, 0))
		delta[key] = current_value - previous_value

	var baseline_updated = reset or update_baseline or not has_previous
	if baseline_updated:
		_state.set_runtime_error_baseline(baseline_name, current)
	return _ok(
		{
			"baseline": baseline_name,
			"has_previous": has_previous,
			"previous": previous if has_previous else {},
			"current": current,
			"delta": delta,
			"baseline_updated": baseline_updated,
		}
	)

func _runtime_observe_after_play(params: Dictionary) -> Dictionary:
	var run_seconds = clampf(float(params.get("run_seconds", params.get("wait_seconds", 1.5))), 0.0, 20.0)
	var session_capture = _state.get_auto_capture_settings()
	var capture_screenshot = false
	if params.has("capture_screenshot"):
		capture_screenshot = bool(params.get("capture_screenshot", false))
	else:
		capture_screenshot = bool(session_capture.get("enabled", false))
	var log_limit = clamp(int(params.get("log_limit", 200)), 1, 2000)
	var capture_mode = _normalize_capture_mode(str(params.get("capture_mode", session_capture.get("mode", "game"))))
	if capture_mode == "":
		return _err(RPC_INVALID_PARAMS, "Invalid capture_mode. Use game or editor")
	var capture_params = {}
	var capture_format = str(params.get("format", session_capture.get("format", "")))
	if capture_format != "":
		var normalized_capture_format = _normalize_capture_format(capture_format)
		if normalized_capture_format == "":
			return _err(RPC_INVALID_PARAMS, "Invalid format. Use png or jpg")
		capture_params["format"] = normalized_capture_format
	if params.has("include_base64"):
		capture_params["include_base64"] = bool(params.get("include_base64", false))
	elif session_capture.has("include_base64"):
		capture_params["include_base64"] = bool(session_capture.get("include_base64", false))
	if params.has("max_base64_bytes"):
		capture_params["max_base64_bytes"] = maxi(0, int(params.get("max_base64_bytes", 0)))
	elif session_capture.has("max_base64_bytes"):
		capture_params["max_base64_bytes"] = maxi(0, int(session_capture.get("max_base64_bytes", 0)))
	if params.has("jpg_quality"):
		capture_params["jpg_quality"] = clampf(float(params.get("jpg_quality", 0.85)), 0.0, 1.0)

	var play = _project_play()
	if run_seconds > 0.0:
		OS.delay_msec(int(run_seconds * 1000.0))

	var logs = _runtime_logs_tail({"limit": log_limit, "level": "all"})
	var parse_errors = _runtime_logs_parse_errors({"limit": log_limit})
	var screenshot_result = null
	if capture_screenshot:
		if capture_mode == "editor":
			screenshot_result = _screenshot_capture_editor(capture_params)
		else:
			screenshot_result = _screenshot_capture_game(capture_params)
	var stop = _project_stop()

	var warning_count := 0
	var error_count := 0
	var log_items = logs.get("data", {}).get("items", [])
	if typeof(log_items) == TYPE_ARRAY:
		for item in log_items:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var level = str(item.get("level", "info"))
			if level == "error":
				error_count += 1
			elif level == "warning":
				warning_count += 1

	var parse_count = int(parse_errors.get("data", {}).get("count", 0))
	var verdict = "pass"
	if error_count > 0 or parse_count > 0:
		verdict = "fail"
	elif warning_count > 0:
		verdict = "warn"

	var payload = {
		"run_seconds": run_seconds,
		"play": play,
		"stop": stop,
		"logs": logs,
		"parse_errors": parse_errors,
		"error_count": error_count,
		"warning_count": warning_count,
		"parse_error_count": parse_count,
		"verdict": verdict,
		"capture_screenshot": capture_screenshot,
		"capture_mode": capture_mode,
	}
	if screenshot_result != null:
		payload["screenshot"] = screenshot_result
	return _ok(payload)

func _runtime_send_and_wait(command: String, args: Array, timeout_ms: int) -> Dictionary:
	if _debugger_plugin == null:
		return _err(ERR_EDITOR_BUSY, "Debugger plugin not initialized")
	if not _debugger_plugin.is_game_connected():
		return _err(ERR_EDITOR_BUSY, "No game session - start the game first")

	var request_id := str(Time.get_ticks_usec())
	var sent: bool = bool(_debugger_plugin.send_command(command, request_id, args))
	if not sent:
		return _err(ERR_EDITOR_BUSY, "Failed to send command to game")

	var timeout_safe: int = clampi(timeout_ms, 100, 10000)
	var deadline: int = Time.get_ticks_msec() + timeout_safe
	while Time.get_ticks_msec() < deadline:
		var result = _debugger_plugin.poll_result(request_id)
		if result != null:
			if typeof(result) != TYPE_DICTIONARY:
				return _err(ERR_EDITOR_BUSY, "Invalid runtime response payload")
			if bool(result.get("ok", false)):
				return _ok({"result": result.get("value", null)})
			return _err(RPC_INVALID_PARAMS, str(result.get("value", "Runtime command failed")))
		OS.delay_msec(RUNTIME_POLL_INTERVAL_MS)
	return _err(ERR_EDITOR_BUSY, "Timed out waiting for runtime command", {"command": command, "timeout_ms": timeout_safe})

func _runtime_ping_game(params: Dictionary) -> Dictionary:
	var timeout_ms := clamp(int(params.get("timeout_ms", RUNTIME_DEFAULT_TIMEOUT_MS)), 100, 10000)
	return _runtime_send_and_wait("ping", [], timeout_ms)

func _runtime_eval_in_game(params: Dictionary) -> Dictionary:
	var expr := str(params.get("expr", "")).strip_edges()
	if expr.is_empty():
		return _err(RPC_INVALID_PARAMS, "expr is required")
	var timeout_ms := clamp(int(params.get("timeout_ms", RUNTIME_DEFAULT_TIMEOUT_MS)), 100, 10000)
	return _runtime_send_and_wait("eval_timed", [expr, timeout_ms], timeout_ms)

func _runtime_node_get_property(params: Dictionary) -> Dictionary:
	var node_path := str(params.get("node_path", "")).strip_edges()
	var property := str(params.get("property", "")).strip_edges()
	if node_path.is_empty() or property.is_empty():
		return _err(RPC_INVALID_PARAMS, "node_path and property are required")
	var timeout_ms := clamp(int(params.get("timeout_ms", RUNTIME_DEFAULT_TIMEOUT_MS)), 100, 10000)
	return _runtime_send_and_wait("inspect", [node_path, property], timeout_ms)

func _runtime_node_call_method(params: Dictionary) -> Dictionary:
	var node_path := str(params.get("node_path", "")).strip_edges()
	var method := str(params.get("method", "")).strip_edges()
	if node_path.is_empty() or method.is_empty():
		return _err(RPC_INVALID_PARAMS, "node_path and method are required")
	var args_json := JSON.stringify(params.get("args", []))
	var timeout_ms := clamp(int(params.get("timeout_ms", RUNTIME_DEFAULT_TIMEOUT_MS)), 100, 10000)
	return _runtime_send_and_wait("call_method", [node_path, method, args_json], timeout_ms)

func _runtime_node_find(params: Dictionary) -> Dictionary:
	var type_filter := str(params.get("type", ""))
	var group_filter := str(params.get("group", ""))
	var name_contains := str(params.get("name_contains", ""))
	var timeout_ms := clamp(int(params.get("timeout_ms", RUNTIME_DEFAULT_TIMEOUT_MS)), 100, 10000)
	return _runtime_send_and_wait("find_nodes", [type_filter, group_filter, name_contains], timeout_ms)

func _runtime_behavior_check(params: Dictionary) -> Dictionary:
	var checks = params.get("checks", [])
	if typeof(checks) != TYPE_ARRAY or checks.is_empty():
		return _err(RPC_INVALID_PARAMS, "checks must be a non-empty array")

	var timeout_ms_per := clamp(int(params.get("timeout_ms", RUNTIME_DEFAULT_TIMEOUT_MS)), 100, 10000)
	var eval_timeout_ms := clamp(timeout_ms_per - 200, 100, 9800)
	var results: Array = []
	var all_passed := true

	for raw_check in checks:
		if typeof(raw_check) != TYPE_DICTIONARY:
			all_passed = false
			results.append(
				{
					"description": "",
					"expr": "",
					"expected": true,
					"actual": null,
					"passed": false,
					"error": "Invalid check payload entry",
				}
			)
			continue

		var description := str(raw_check.get("description", ""))
		var expr := str(raw_check.get("expr", "")).strip_edges()
		var expected := bool(raw_check.get("expected", true))
		var delay_ms := clamp(int(raw_check.get("delay_ms", 0)), 0, 5000)
		if delay_ms > 0:
			OS.delay_msec(delay_ms)

		var eval_result := _runtime_send_and_wait("eval_timed", [expr, eval_timeout_ms], timeout_ms_per)
		var passed := false
		var actual = null
		var error_msg := ""
		if eval_result.get("ok", false):
			actual = eval_result.get("data", {}).get("result", null)
			passed = bool(actual) == expected
		else:
			error_msg = str(eval_result.get("message", "eval failed"))

		results.append(
			{
				"description": description,
				"expr": expr,
				"expected": expected,
				"actual": actual,
				"passed": passed,
				"error": error_msg,
			}
		)
		if not passed:
			all_passed = false

	return _ok({"all_passed": all_passed, "checks": results})

func _assets_images_search(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("root_path", "res://")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var root_path = str(normalized.get("path", "res://"))
	var query = str(params.get("query", "")).strip_edges().to_lower()
	var limit = clamp(int(params.get("limit", 200)), 1, 2000)
	var include_dimensions = bool(params.get("include_dimensions", false))
	var extensions: Array[String] = _to_string_array(params.get("extensions", []))
	if extensions.is_empty():
		var default_extensions: Array[String] = ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg"]
		extensions = default_extensions

	var entries: Array[Dictionary] = []
	_collect_dir_entries(root_path, true, true, false, entries)
	var items: Array[Dictionary] = []
	for entry in entries:
		if items.size() >= limit:
			break
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var file_path = str(entry.get("path", ""))
		if file_path == "":
			continue
		if not _path_has_any_extension(file_path, extensions):
			continue
		var file_name = file_path.get_file()
		if query != "" and file_path.to_lower().find(query) == -1 and file_name.to_lower().find(query) == -1:
			continue
		var item = {
			"path": file_path,
			"name": file_name,
			"extension": file_path.get_extension().to_lower(),
			"bytes": _file_size_bytes(file_path),
		}
		if include_dimensions:
			var image = Image.new()
			var load_err = image.load(file_path)
			if load_err == OK:
				item["width"] = image.get_width()
				item["height"] = image.get_height()
			else:
				item["width"] = 0
				item["height"] = 0
				item["image_error"] = load_err
		items.append(item)
	return _ok(
		{
			"root_path": root_path,
			"query": query,
			"extensions": extensions,
			"count": items.size(),
			"items": items,
		}
	)

func _assets_images_preview(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if path == "":
		return _err(RPC_INVALID_PARAMS, "Missing path")
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "File does not exist: %s" % path)
	var image = Image.new()
	var load_err = image.load(path)
	if load_err != OK:
		if path.to_lower().ends_with(".svg"):
			var svg_bytes = FileAccess.get_file_as_bytes(path)
			return _ok(
				{
					"path": path,
					"format": "svg",
					"width": 0,
					"height": 0,
					"bytes": svg_bytes.size(),
					"sha256": FileAccess.get_sha256(path),
					"previewable": false,
					"reason": "SVG raster preview is not available via Image.load",
				}
			)
		return _err(ERR_EDITOR_BUSY, "Failed to load image preview", {"error": load_err, "path": path})

	var bytes = FileAccess.get_file_as_bytes(path)
	var include_base64 = bool(params.get("include_base64", false))
	var max_base64_bytes = maxi(0, int(params.get("max_base64_bytes", 0)))
	var include_inline = include_base64 and (max_base64_bytes == 0 or bytes.size() <= max_base64_bytes)
	var payload = {
		"path": path,
		"format": path.get_extension().to_lower(),
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": bytes.size(),
		"sha256": FileAccess.get_sha256(path),
		"base64_included": include_inline,
	}
	if include_inline:
		payload["base64"] = Marshalls.raw_to_base64(bytes)
	elif include_base64:
		payload["base64_omitted_reason"] = "Image exceeds max_base64_bytes"
	return _ok(payload)

func _filesystem_list_dir(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "res://")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var base_path = str(normalized.get("path", "res://"))
	var recursive = bool(params.get("recursive", false))
	var include_files = bool(params.get("include_files", true))
	var include_dirs = bool(params.get("include_dirs", true))

	var entries: Array[Dictionary] = []
	_collect_dir_entries(base_path, recursive, include_files, include_dirs, entries)
	return _ok({"path": base_path, "entries": entries})

func _filesystem_read_text(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err(RPC_INVALID_PARAMS, "File does not exist: %s" % path)
	var content = FileAccess.get_file_as_string(path)
	return _ok({"path": path, "content": content})

func _filesystem_read_text_batch(params: Dictionary) -> Dictionary:
	var items = params.get("paths", [])
	if typeof(items) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "paths must be an array")

	var max_items := clamp(items.size(), 0, 200)
	var results: Array[Dictionary] = []
	var all_ok := true
	for i in range(0, max_items):
		var entry_path = str(items[i])
		var result = _filesystem_read_text({"path": entry_path})
		if result.get("ok", false):
			results.append({
				"path": result.get("data", {}).get("path", entry_path),
				"ok": true,
				"content": result.get("data", {}).get("content", ""),
			})
		else:
			all_ok = false
			results.append({
				"path": entry_path,
				"ok": false,
				"error": result.get("message", "Unknown error"),
				"code": result.get("code", -32000),
			})
	return _ok({"ok": all_ok, "items": results, "count": results.size()})

func _filesystem_write_text(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var path = str(normalized.get("path", ""))
	var content = str(params.get("content", ""))
	var overwrite = bool(params.get("overwrite", false))

	if FileAccess.file_exists(path) and not overwrite:
		return _err(RPC_INVALID_PARAMS, "File exists and overwrite=false")

	_undo_capture_file_state(path)
	var write_result = _write_text_file(path, content)
	if not write_result.get("ok", false):
		return _err(ERR_EDITOR_BUSY, str(write_result.get("error", "Failed to write file")))
	return _ok({"path": path, "written_bytes": content.to_utf8_buffer().size()})

func _filesystem_write_text_batch(params: Dictionary) -> Dictionary:
	var items = params.get("items", [])
	if typeof(items) != TYPE_ARRAY:
		return _err(RPC_INVALID_PARAMS, "items must be an array")

	var max_items := clamp(items.size(), 0, 200)
	var results: Array[Dictionary] = []
	var all_ok := true
	for i in range(0, max_items):
		var item = items[i]
		if typeof(item) != TYPE_DICTIONARY:
			all_ok = false
			results.append({"ok": false, "error": "Invalid item payload", "code": RPC_INVALID_PARAMS})
			continue

		var result = _filesystem_write_text({
			"path": item.get("path", ""),
			"content": item.get("content", ""),
			"overwrite": bool(item.get("overwrite", false)),
		})
		if result.get("ok", false):
			results.append({
				"path": result.get("data", {}).get("path", ""),
				"ok": true,
				"written_bytes": result.get("data", {}).get("written_bytes", 0),
			})
		else:
			all_ok = false
			results.append({
				"path": str(item.get("path", "")),
				"ok": false,
				"error": result.get("message", "Unknown error"),
				"code": result.get("code", -32000),
			})
	return _ok({"ok": all_ok, "items": results, "count": results.size()})

func _filesystem_search(params: Dictionary) -> Dictionary:
	var normalized = _guard.normalize_res_path(str(params.get("path", "res://")))
	if not normalized.get("ok", false):
		return _err(ERR_PATH_VIOLATION, str(normalized.get("error", "Invalid path")))
	var base_path = str(normalized.get("path", "res://"))
	var pattern = str(params.get("pattern", ""))
	if pattern == "":
		return _err(RPC_INVALID_PARAMS, "Missing pattern")
	var max_results = int(params.get("max_results", 100))
	max_results = clamp(max_results, 1, 2000)

	var files: Array[Dictionary] = []
	_collect_matching_files(base_path, pattern, files, max_results)
	return _ok({"pattern": pattern, "matches": files, "count": files.size()})

func _undo_begin_action(params: Dictionary) -> Dictionary:
	if _undo_action_open:
		return _err(ERR_EDITOR_BUSY, "Undo action is already open", {"action_name": _undo_action_name})

	var root = _current_root()
	if root == null:
		return _err(ERR_SCENE_CONTEXT, "No edited scene")

	var action_name = str(params.get("name", "mcp_action")).strip_edges()
	if action_name == "":
		action_name = "mcp_action"

	_undo_snapshot_counter += 1
	var snapshot_path = "res://.godot_mcp_tmp/undo_snapshot_%d.tscn" % _undo_snapshot_counter
	var packed = PackedScene.new()
	var pack_err = packed.pack(root)
	if pack_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to capture undo snapshot", {"error": pack_err})
	var save_err = ResourceSaver.save(packed, snapshot_path)
	if save_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save undo snapshot", {"error": save_err})

	_undo_action_open = true
	_undo_action_name = action_name
	_undo_scene_snapshot_path = snapshot_path
	_undo_scene_original_path = str(root.scene_file_path)
	_undo_file_snapshots.clear()
	_undo_started_at_unix = int(Time.get_unix_time_from_system())
	_undo_change_count = 0
	return _ok(
		{
			"action_open": true,
			"action_name": _undo_action_name,
			"snapshot_scene": _undo_scene_snapshot_path,
			"original_scene": _undo_scene_original_path,
		}
	)

func _undo_end_action() -> Dictionary:
	if not _undo_action_open:
		return _err(RPC_INVALID_PARAMS, "No undo action is open")

	var info = {
		"ended": true,
		"action_name": _undo_action_name,
		"change_count": _undo_change_count,
		"captured_files": _undo_file_snapshots.size(),
	}
	_undo_clear_action(true)
	return _ok(info)

func _undo_commit() -> Dictionary:
	if not _undo_action_open:
		return _err(RPC_INVALID_PARAMS, "No undo action is open")

	var info = {
		"committed": true,
		"action_name": _undo_action_name,
		"change_count": _undo_change_count,
		"captured_files": _undo_file_snapshots.size(),
	}
	_undo_clear_action(true)
	return _ok(info)

func _undo_rollback() -> Dictionary:
	if not _undo_action_open:
		return _err(RPC_INVALID_PARAMS, "No undo action is open")
	if _undo_replaying:
		return _err(ERR_EDITOR_BUSY, "Undo rollback is already running")

	_undo_replaying = true
	var file_restore = _undo_restore_files()
	var scene_restore = _undo_restore_scene()
	_undo_replaying = false

	var payload = {
		"rolled_back": bool(file_restore.get("ok", false)) and bool(scene_restore.get("ok", false)),
		"action_name": _undo_action_name,
		"file_restore": file_restore,
		"scene_restore": scene_restore,
	}
	var restore_ok = bool(payload.get("rolled_back", false))
	_undo_clear_action(true)
	if restore_ok:
		return _ok(payload)
	return _err(ERR_EDITOR_BUSY, "Undo rollback failed", payload)

func _undo_capture_file_state(path: String) -> void:
	if not _undo_action_open or _undo_replaying:
		return
	if _undo_file_snapshots.has(path):
		return

	if FileAccess.file_exists(path):
		_undo_file_snapshots[path] = {
			"existed": true,
			"content": FileAccess.get_file_as_string(path),
		}
	else:
		_undo_file_snapshots[path] = {
			"existed": false,
			"content": "",
		}

func _undo_restore_files() -> Dictionary:
	var restored := 0
	var failures: Array[Dictionary] = []
	for path in _undo_file_snapshots.keys():
		var item = _undo_file_snapshots[path]
		var existed = bool(item.get("existed", false))
		if existed:
			var write_result = _write_text_file(str(path), str(item.get("content", "")))
			if write_result.get("ok", false):
				restored += 1
			else:
				failures.append({"path": path, "error": str(write_result.get("error", "Failed to restore file"))})
		else:
			var delete_err = _delete_res_file(str(path))
			if delete_err == OK or delete_err == ERR_FILE_NOT_FOUND:
				restored += 1
			else:
				failures.append({"path": path, "error": "Failed to delete new file", "code": delete_err})
	return {"ok": failures.is_empty(), "restored": restored, "failed": failures}

func _undo_restore_scene() -> Dictionary:
	if _undo_scene_snapshot_path == "":
		return {"ok": true, "skipped": true}
	if not FileAccess.file_exists(_undo_scene_snapshot_path):
		return {"ok": false, "error": "Undo snapshot scene is missing", "path": _undo_scene_snapshot_path}

	var iface = _plugin.get_editor_interface()
	var snapshot = ResourceLoader.load(_undo_scene_snapshot_path)
	if snapshot == null or not (snapshot is PackedScene):
		return {"ok": false, "error": "Failed to load undo snapshot scene", "path": _undo_scene_snapshot_path}

	if _undo_scene_original_path != "":
		var save_err = ResourceSaver.save(snapshot, _undo_scene_original_path)
		if save_err != OK:
			return {"ok": false, "error": "Failed to restore original scene", "code": save_err}
		if iface.has_method("close_scene"):
			for _i in range(0, 4):
				var current = _current_root()
				if current == null:
					break
				iface.call("close_scene")
		iface.open_scene_from_path(_undo_scene_original_path)
		return {"ok": true, "restored_scene": _undo_scene_original_path, "snapshot_scene": _undo_scene_snapshot_path}

	iface.open_scene_from_path(_undo_scene_snapshot_path)
	return {"ok": true, "restored_scene": _undo_scene_snapshot_path, "snapshot_scene": _undo_scene_snapshot_path}

func _undo_clear_action(delete_snapshot: bool) -> void:
	if delete_snapshot and _undo_scene_snapshot_path != "":
		_delete_res_file(_undo_scene_snapshot_path)
	_undo_action_open = false
	_undo_action_name = ""
	_undo_scene_snapshot_path = ""
	_undo_scene_original_path = ""
	_undo_file_snapshots.clear()
	_undo_started_at_unix = 0
	_undo_change_count = 0

func _undo_register_node_added(_node_path: String) -> void:
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1

func _undo_register_node_removed_snapshot(_node: Node, _parent: Node) -> void:
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1

func _undo_register_node_reparent(_node_path: String, _old_parent_path: String) -> void:
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1

func _undo_register_node_rename(_node_path: String, _old_name: String) -> void:
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1

func _undo_register_node_property(_node_path: String, _property_name: String, _previous_value: Variant) -> void:
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1

func _undo_register_node_properties(_node_path: String, _old_values: Dictionary) -> void:
	if _undo_action_open and not _undo_replaying:
		_undo_change_count += 1

func _capabilities_get() -> Dictionary:
	return _ok({
		"godot_version": str(Engine.get_version_info().get("string", "unknown")),
		"supported_methods": _guard.ALLOWED_METHODS,
		"limits": {
			"max_search_results": 2000,
			"max_diagnostics": 200,
			"max_runtime_logs": 2000,
		},
		"feature_flags": {
			"guarded_actions": true,
			"filesystem_tools": true,
			"script_tools": true,
			"resource_tools": true,
			"animation_tools": true,
			"inspector_tools": true,
			"refactor_tools": true,
			"screenshot_tools": true,
			"runtime_observability_tools": true,
			"editor_ui_tools": true,
			"inspector_preset_tools": true,
			"editor_layout_tools": true,
			"editor_context_tools": true,
			"runtime_stream_tools": true,
			"session_auto_capture_tools": true,
			"asset_image_tools": true,
			"intent_suggestion_tools": true,
			"runtime_behavior_verification": true,
			"runtime_gdscript_eval": true,
		},
	})

func _session_get_state() -> Dictionary:
	var root = _current_root()
	var root_path = ""
	if root != null:
		root_path = str(root.get_path())
	var info = _state.snapshot()
	info["edited_scene_root_path"] = root_path
	info["edited_scene_file_path"] = "" if root == null else str(root.scene_file_path)
	info["undo_action_open"] = _undo_action_open
	info["undo_action_name"] = _undo_action_name
	info["undo_change_count"] = _undo_change_count
	info["auto_capture"] = _state.get_auto_capture_settings()
	return _ok(info)

func _session_auto_capture_get() -> Dictionary:
	return _ok(_state.get_auto_capture_settings())

func _session_auto_capture_set(params: Dictionary) -> Dictionary:
	var patch = {}
	if params.has("enabled"):
		patch["enabled"] = bool(params.get("enabled", false))
	if params.has("mode"):
		var mode = _normalize_capture_mode(str(params.get("mode", "")))
		if mode == "":
			return _err(RPC_INVALID_PARAMS, "Invalid mode. Use game or editor")
		patch["mode"] = mode
	if params.has("format"):
		var format = _normalize_capture_format(str(params.get("format", "")))
		if format == "":
			return _err(RPC_INVALID_PARAMS, "Invalid format. Use png or jpg")
		patch["format"] = format
	if params.has("include_base64"):
		patch["include_base64"] = bool(params.get("include_base64", false))
	if params.has("max_base64_bytes"):
		patch["max_base64_bytes"] = maxi(0, int(params.get("max_base64_bytes", 0)))
	var updated = _state.update_auto_capture_settings(patch)
	return _ok(updated)

func _intent_suggest_payload(params: Dictionary) -> Dictionary:
	var method = str(params.get("method", "")).strip_edges()
	var context = params.get("context", {})
	if typeof(context) != TYPE_DICTIONARY:
		context = {}
	var intent_text = str(params.get("intent", params.get("query", ""))).strip_edges()
	var suggestions: Array[Dictionary] = []
	if method != "":
		var template = _intent_template_for_method(method, context)
		if template.is_empty():
			return _err(RPC_INVALID_PARAMS, "Unsupported method for intent suggestions: %s" % method)
		suggestions.append({"method": method, "payload": template, "confidence": 0.95, "reason": "Explicit method requested"})
	else:
		var methods = _intent_methods_from_text(intent_text)
		for candidate in methods:
			var candidate_method = str(candidate)
			var template = _intent_template_for_method(candidate_method, context)
			if template.is_empty():
				continue
			suggestions.append(
				{
					"method": candidate_method,
					"payload": template,
					"confidence": 0.75,
					"reason": "Matched by intent keywords",
				}
			)
	return _ok(
		{
			"intent": intent_text,
			"count": suggestions.size(),
			"suggestions": suggestions,
		}
	)

func _current_root() -> Node:
	return _plugin.get_editor_interface().get_edited_scene_root()

func _resolve_node(root: Node, node_path: String) -> Node:
	if root == null:
		return null
	if node_path == "" or node_path == ".":
		return root
	return root.get_node_or_null(NodePath(node_path))

func _serialize_tree(node: Node) -> Dictionary:
	var children: Array[Dictionary] = []
	for child in node.get_children():
		if child is Node:
			children.append(_serialize_tree(child))
	return {
		"name": node.name,
		"path": str(node.get_path()),
		"type": node.get_class(),
		"children": children,
	}

func _collect_scene_instance_nodes(parent: Node, root: Node, filter_scene_path: String) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var stack: Array[Node] = [parent]
	while stack.size() > 0:
		var current = stack.pop_back()
		if current != root:
			var scene_path = str(current.scene_file_path)
			if scene_path != "" and (filter_scene_path == "" or scene_path == filter_scene_path):
				items.append(
					{
						"name": current.name,
						"path": str(current.get_path()),
						"type": current.get_class(),
						"scene_path": scene_path,
					}
				)
		for child in current.get_children():
			if child is Node:
				stack.append(child)
	return items

func _collect_scene_instance_node_refs(parent: Node, root: Node, filter_scene_path: String) -> Array[Dictionary]:
	var refs: Array[Dictionary] = []
	var stack: Array[Node] = [parent]
	while stack.size() > 0:
		var current = stack.pop_back()
		if current != root:
			var scene_path = str(current.scene_file_path)
			if scene_path != "" and scene_path == filter_scene_path:
				refs.append(
					{
						"name": current.name,
						"path": str(current.get_path()),
						"scene_path": scene_path,
					}
				)
		for child in current.get_children():
			if child is Node:
				stack.append(child)
	return refs

func _copy_node_runtime_state(old_node: Node, new_node: Node) -> void:
	if old_node is Node2D and new_node is Node2D:
		new_node.position = old_node.position
		new_node.rotation = old_node.rotation
		new_node.scale = old_node.scale
		new_node.z_index = old_node.z_index
		new_node.z_as_relative = old_node.z_as_relative
	elif old_node is Node3D and new_node is Node3D:
		new_node.transform = old_node.transform
	elif old_node is Control and new_node is Control:
		new_node.position = old_node.position
		new_node.size = old_node.size

	if old_node is CanvasItem and new_node is CanvasItem:
		new_node.visible = old_node.visible
	new_node.process_priority = old_node.process_priority

func _serialize_input_event(event: InputEvent) -> Dictionary:
	var payload = {
		"type": "unknown",
		"class": event.get_class(),
		"as_text": event.as_text(),
		"device": int(event.device),
	}
	if event is InputEventKey:
		payload["type"] = "key"
		payload["keycode"] = int(event.keycode)
		payload["physical_keycode"] = int(event.physical_keycode)
		payload["unicode"] = int(event.unicode)
		payload["pressed"] = bool(event.pressed)
		payload["echo"] = bool(event.echo)
		payload["shift_pressed"] = bool(event.shift_pressed)
		payload["alt_pressed"] = bool(event.alt_pressed)
		payload["ctrl_pressed"] = bool(event.ctrl_pressed)
		payload["meta_pressed"] = bool(event.meta_pressed)
	elif event is InputEventMouseButton:
		payload["type"] = "mouse_button"
		payload["button_index"] = int(event.button_index)
		payload["pressed"] = bool(event.pressed)
		payload["double_click"] = bool(event.double_click)
		payload["factor"] = float(event.factor)
	elif event is InputEventJoypadButton:
		payload["type"] = "joypad_button"
		payload["button_index"] = int(event.button_index)
		payload["pressed"] = bool(event.pressed)
	elif event is InputEventJoypadMotion:
		payload["type"] = "joypad_motion"
		payload["axis"] = int(event.axis)
		payload["axis_value"] = float(event.axis_value)
	elif event is InputEventAction:
		payload["type"] = "action"
		payload["action"] = str(event.action)
		payload["pressed"] = bool(event.pressed)
		payload["strength"] = float(event.strength)
	return payload

func _deserialize_input_event(spec: Dictionary) -> Variant:
	var event_type = str(spec.get("type", "")).to_lower()
	match event_type:
		"key":
			var key_event := InputEventKey.new()
			key_event.keycode = _parse_keycode_value(spec.get("keycode", spec.get("key", null)))
			key_event.physical_keycode = int(spec.get("physical_keycode", 0))
			key_event.unicode = int(spec.get("unicode", 0))
			key_event.pressed = bool(spec.get("pressed", true))
			key_event.echo = bool(spec.get("echo", false))
			key_event.shift_pressed = bool(spec.get("shift_pressed", false))
			key_event.alt_pressed = bool(spec.get("alt_pressed", false))
			key_event.ctrl_pressed = bool(spec.get("ctrl_pressed", false))
			key_event.meta_pressed = bool(spec.get("meta_pressed", false))
			key_event.device = int(spec.get("device", 0))
			return key_event
		"mouse_button":
			var mouse_button_event := InputEventMouseButton.new()
			mouse_button_event.button_index = int(spec.get("button_index", MOUSE_BUTTON_LEFT))
			mouse_button_event.pressed = bool(spec.get("pressed", true))
			mouse_button_event.double_click = bool(spec.get("double_click", false))
			mouse_button_event.factor = float(spec.get("factor", 1.0))
			mouse_button_event.device = int(spec.get("device", 0))
			return mouse_button_event
		"joypad_button":
			var joy_button_event := InputEventJoypadButton.new()
			joy_button_event.button_index = int(spec.get("button_index", 0))
			joy_button_event.pressed = bool(spec.get("pressed", true))
			joy_button_event.device = int(spec.get("device", 0))
			return joy_button_event
		"joypad_motion":
			var joy_motion_event := InputEventJoypadMotion.new()
			joy_motion_event.axis = int(spec.get("axis", 0))
			joy_motion_event.axis_value = float(spec.get("axis_value", 0.0))
			joy_motion_event.device = int(spec.get("device", 0))
			return joy_motion_event
		"action":
			var action_event := InputEventAction.new()
			action_event.action = StringName(str(spec.get("action", "")))
			action_event.pressed = bool(spec.get("pressed", true))
			action_event.strength = float(spec.get("strength", 1.0))
			action_event.device = int(spec.get("device", 0))
			return action_event
		_:
			return null

func _parse_keycode_value(raw_value: Variant) -> int:
	match typeof(raw_value):
		TYPE_INT, TYPE_FLOAT:
			return int(raw_value)
		TYPE_STRING:
			var text = str(raw_value).strip_edges()
			if text == "":
				return 0
			if text.is_valid_int():
				return int(text)
			return int(OS.find_keycode_from_string(text))
		_:
			return 0

func _sync_input_action_to_project_settings(action_name: String) -> int:
	var key = "input/%s" % action_name
	if InputMap.has_action(action_name):
		var setting_value = {
			"deadzone": float(InputMap.action_get_deadzone(action_name)),
			"events": InputMap.action_get_events(action_name),
		}
		ProjectSettings.set_setting(key, setting_value)
	else:
		if ProjectSettings.has_method("clear"):
			ProjectSettings.call("clear", key)
		else:
			ProjectSettings.set_setting(key, null)
	return ProjectSettings.save()

func _animation_resolve_player(params: Dictionary) -> Dictionary:
	var root = _current_root()
	if root == null:
		return {"ok": false, "code": ERR_SCENE_CONTEXT, "message": "No edited scene"}
	var player_path = str(params.get("player_path", "")).strip_edges()
	if player_path == "":
		player_path = "."
	var player_node = _resolve_node(root, player_path)
	if player_node == null:
		return {"ok": false, "code": RPC_INVALID_PARAMS, "message": "AnimationPlayer not found: %s" % player_path}
	if not (player_node is AnimationPlayer):
		return {"ok": false, "code": RPC_INVALID_PARAMS, "message": "Node is not an AnimationPlayer: %s" % player_path}
	return {"ok": true, "root": root, "player": player_node}

func _animation_get_or_create_default_library(player: AnimationPlayer) -> Dictionary:
	if player.has_animation_library(""):
		var existing_library = player.get_animation_library("")
		if existing_library != null:
			return {"ok": true, "library": existing_library}
	var created := AnimationLibrary.new()
	var err = player.add_animation_library("", created)
	if err != OK:
		return {"ok": false, "error": "Failed to add default animation library", "code": err}
	return {"ok": true, "library": created}

func _animation_resolve_animation(params: Dictionary) -> Dictionary:
	var resolved_player = _animation_resolve_player(params)
	if not resolved_player.get("ok", false):
		return resolved_player
	var player: AnimationPlayer = resolved_player.get("player", null)
	var ensure_library = _animation_get_or_create_default_library(player)
	if not ensure_library.get("ok", false):
		return {"ok": false, "code": ERR_EDITOR_BUSY, "message": str(ensure_library.get("error", "Failed to access animation library"))}
	var library: AnimationLibrary = ensure_library.get("library", null)
	var animation_name = str(params.get("animation_name", "")).strip_edges()
	if animation_name == "":
		return {"ok": false, "code": RPC_INVALID_PARAMS, "message": "Missing animation_name"}
	if not library.has_animation(animation_name):
		return {"ok": false, "code": RPC_INVALID_PARAMS, "message": "Animation not found: %s" % animation_name}
	return {
		"ok": true,
		"player": player,
		"library": library,
		"animation_name": animation_name,
		"animation": library.get_animation(animation_name),
	}

func _animation_parse_track_type(name: String) -> int:
	match name.to_lower():
		"value":
			return Animation.TYPE_VALUE
		"position_3d":
			return Animation.TYPE_POSITION_3D
		"rotation_3d":
			return Animation.TYPE_ROTATION_3D
		"scale_3d":
			return Animation.TYPE_SCALE_3D
		"blend_shape":
			return Animation.TYPE_BLEND_SHAPE
		"method":
			return Animation.TYPE_METHOD
		"bezier":
			return Animation.TYPE_BEZIER
		"audio":
			return Animation.TYPE_AUDIO
		"animation":
			return Animation.TYPE_ANIMATION
		_:
			return -1

func _animation_track_type_name(track_type: int) -> String:
	match track_type:
		Animation.TYPE_VALUE:
			return "value"
		Animation.TYPE_POSITION_3D:
			return "position_3d"
		Animation.TYPE_ROTATION_3D:
			return "rotation_3d"
		Animation.TYPE_SCALE_3D:
			return "scale_3d"
		Animation.TYPE_BLEND_SHAPE:
			return "blend_shape"
		Animation.TYPE_METHOD:
			return "method"
		Animation.TYPE_BEZIER:
			return "bezier"
		Animation.TYPE_AUDIO:
			return "audio"
		Animation.TYPE_ANIMATION:
			return "animation"
		_:
			return "unknown"

func _animation_parse_loop_mode(value: Variant) -> int:
	if typeof(value) == TYPE_BOOL:
		return Animation.LOOP_LINEAR if bool(value) else Animation.LOOP_NONE
	var text = str(value).to_lower()
	match text:
		"none", "off", "false", "0":
			return Animation.LOOP_NONE
		"linear", "loop", "true", "1":
			return Animation.LOOP_LINEAR
		"pingpong", "ping_pong":
			return Animation.LOOP_PINGPONG
		_:
			return Animation.LOOP_NONE

func _animation_loop_mode_name(loop_mode: int) -> String:
	match loop_mode:
		Animation.LOOP_NONE:
			return "none"
		Animation.LOOP_LINEAR:
			return "linear"
		Animation.LOOP_PINGPONG:
			return "pingpong"
		_:
			return "none"

func _detect_active_panel_from_focus(owner_name: String, owner_class: String) -> String:
	var hay = ("%s %s" % [owner_name, owner_class]).to_lower()
	if hay.find("inspector") != -1:
		return "inspector"
	if hay.find("filesystem") != -1:
		return "filesystem"
	if hay.find("output") != -1 or hay.find("debugger") != -1:
		return "output"
	if hay.find("scene") != -1 and hay.find("tree") != -1:
		return "scene_tree"
	return "unknown"

func _find_panel_control(root_control: Control, panel: String) -> Control:
	var stack: Array[Control] = [root_control]
	while stack.size() > 0:
		var current = stack.pop_back()
		var name = str(current.name).to_lower()
		var class_name_text = str(current.get_class()).to_lower()
		var hay = name + " " + class_name_text
		var matches = false
		match panel:
			"inspector":
				matches = hay.find("inspector") != -1
			"filesystem":
				matches = hay.find("filesystem") != -1
			"scene_tree":
				matches = hay.find("scene") != -1 and hay.find("tree") != -1
			"output":
				matches = hay.find("output") != -1 or hay.find("debugger") != -1
		if matches:
			return current
		for child in current.get_children():
			if child is Control:
				stack.append(child)
	return null

func _collect_editor_dock_layout(base_control: Control) -> Dictionary:
	var panels: Array[Dictionary] = []
	var panel_names: Array[String] = ["scene_tree", "inspector", "filesystem", "output"]
	for panel_name in panel_names:
		var control = _find_panel_control(base_control, panel_name)
		panels.append(
			{
				"panel": panel_name,
				"visible": control != null and control.is_visible_in_tree(),
				"tab_index": _control_current_tab_index(control),
				"control_name": "" if control == null else str(control.name),
				"control_class": "" if control == null else str(control.get_class()),
			}
		)
	return {
		"panels": panels,
		"split_ratios": _collect_editor_split_ratios(base_control),
		"dock_slots": _collect_editor_dock_slots(base_control),
		"window_size": {
			"width": int(base_control.size.x),
			"height": int(base_control.size.y),
		},
	}

func _collect_editor_split_ratios(base_control: Control) -> Array[Dictionary]:
	var ratios: Array[Dictionary] = []
	var stack: Array[Control] = [base_control]
	while stack.size() > 0:
		var current = stack.pop_back()
		if current is SplitContainer:
			var split = current as SplitContainer
			var class_name_text = str(split.get_class())
			var is_vertical = class_name_text.find("VSplit") != -1
			var total = split.size.y if is_vertical else split.size.x
			var ratio := 0.5
			if total > 0.0:
				ratio = clampf(float(split.split_offset) / float(total), 0.0, 1.0)
			ratios.append(
				{
					"container": str(split.name),
					"class_name": class_name_text,
					"ratio": ratio,
					"split_offset": int(split.split_offset),
				}
			)
		for child in current.get_children():
			if child is Control:
				stack.append(child)
	return ratios

func _collect_editor_dock_slots(base_control: Control) -> Array[Dictionary]:
	var slots: Array[Dictionary] = []
	var stack: Array[Control] = [base_control]
	while stack.size() > 0:
		var current = stack.pop_back()
		if current is TabContainer:
			var tabs_control = current as TabContainer
			var tabs: Array[String] = []
			for child in tabs_control.get_children():
				if child is Control:
					tabs.append(str(child.name))
			var current_tab_name = ""
			if tabs_control.get_tab_count() > 0:
				var tab_index = tabs_control.current_tab
				if tab_index >= 0 and tab_index < tabs_control.get_tab_count():
					current_tab_name = str(tabs_control.get_tab_title(tab_index))
			slots.append(
				{
					"slot": str(tabs_control.name),
					"path": str(tabs_control.get_path()),
					"tabs": tabs,
					"current_tab": current_tab_name,
				}
			)
		for child in current.get_children():
			if child is Control:
				stack.append(child)
	return slots

func _control_current_tab_index(control: Control) -> int:
	if control == null:
		return -1
	if control is TabContainer:
		return int((control as TabContainer).current_tab)
	return -1

func _serialize_selection_node_details(node: Node, root: Node) -> Dictionary:
	var owner_path = ""
	if node.owner != null:
		owner_path = str(node.owner.get_path())
	var script_path = ""
	var script_res = node.get_script()
	if script_res != null and script_res is Script:
		script_path = str(script_res.resource_path)
	return {
		"name": node.name,
		"path": str(node.get_path()),
		"type": node.get_class(),
		"owner_path": owner_path,
		"scene_path": str(node.scene_file_path),
		"script_path": script_path,
		"is_scene_instance": str(node.scene_file_path) != "",
		"is_root": node == root,
	}

func _variant_type_name(variant_type: int) -> String:
	match variant_type:
		TYPE_NIL:
			return "nil"
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING:
			return "String"
		TYPE_VECTOR2:
			return "Vector2"
		TYPE_VECTOR2I:
			return "Vector2i"
		TYPE_RECT2:
			return "Rect2"
		TYPE_RECT2I:
			return "Rect2i"
		TYPE_VECTOR3:
			return "Vector3"
		TYPE_VECTOR3I:
			return "Vector3i"
		TYPE_TRANSFORM2D:
			return "Transform2D"
		TYPE_VECTOR4:
			return "Vector4"
		TYPE_VECTOR4I:
			return "Vector4i"
		TYPE_PLANE:
			return "Plane"
		TYPE_QUATERNION:
			return "Quaternion"
		TYPE_AABB:
			return "AABB"
		TYPE_BASIS:
			return "Basis"
		TYPE_TRANSFORM3D:
			return "Transform3D"
		TYPE_PROJECTION:
			return "Projection"
		TYPE_COLOR:
			return "Color"
		TYPE_STRING_NAME:
			return "StringName"
		TYPE_NODE_PATH:
			return "NodePath"
		TYPE_RID:
			return "RID"
		TYPE_OBJECT:
			return "Object"
		TYPE_CALLABLE:
			return "Callable"
		TYPE_SIGNAL:
			return "Signal"
		TYPE_DICTIONARY:
			return "Dictionary"
		TYPE_ARRAY:
			return "Array"
		TYPE_PACKED_BYTE_ARRAY:
			return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY:
			return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY:
			return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY:
			return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY:
			return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY:
			return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY:
			return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY:
			return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY:
			return "PackedColorArray"
		_:
			return str(variant_type)

func _inspector_preview_node_patches(node: Node, raw_patches: Array) -> Dictionary:
	var meta_map: Dictionary = {}
	for prop in node.get_property_list():
		if typeof(prop) != TYPE_DICTIONARY:
			continue
		var prop_name = str(prop.get("name", ""))
		if prop_name == "":
			continue
		meta_map[prop_name] = prop

	var items: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	var valid_count := 0
	var invalid_count := 0
	var mismatch_count := 0
	var would_change_count := 0
	for patch_item in raw_patches:
		if typeof(patch_item) != TYPE_DICTIONARY:
			invalid_count += 1
			errors.append({"error": "patch item must be a dictionary"})
			items.append({"ok": false, "would_change": false, "error": "patch item must be a dictionary"})
			continue
		var path = str(patch_item.get("path", "")).strip_edges()
		if path == "":
			invalid_count += 1
			errors.append({"error": "patch.path is required"})
			items.append({"path": path, "ok": false, "would_change": false, "error": "patch.path is required"})
			continue
		if not meta_map.has(path):
			invalid_count += 1
			errors.append({"path": path, "error": "Unknown property"})
			items.append({"path": path, "ok": false, "would_change": false, "error": "Unknown property"})
			continue
		var meta = meta_map[path]
		var expected_type = int(meta.get("type", TYPE_NIL))
		var next_value = _decode_value(patch_item.get("value", null))
		var next_type = typeof(next_value)
		if not _inspector_is_type_compatible(expected_type, next_value):
			invalid_count += 1
			mismatch_count += 1
			errors.append({"path": path, "error": "Type mismatch", "expected_type": _variant_type_name(expected_type), "value_type": _variant_type_name(next_type)})
			items.append(
				{
					"path": path,
					"ok": false,
					"would_change": false,
					"error": "Type mismatch",
					"expected_type": _variant_type_name(expected_type),
					"value_type": _variant_type_name(next_type),
				}
			)
			continue
		valid_count += 1
		var current_encoded = _encode_value(node.get(path))
		var next_encoded = _encode_value(next_value)
		var would_change = current_encoded != next_encoded
		if would_change:
			would_change_count += 1
		items.append(
			{
				"path": path,
				"ok": true,
				"would_change": would_change,
				"current": current_encoded,
				"next": next_encoded,
				"expected_type": _variant_type_name(expected_type),
				"value_type": _variant_type_name(next_type),
			}
		)

	return {
		"patch_count": raw_patches.size(),
		"valid_count": valid_count,
		"invalid_count": invalid_count,
		"type_mismatch_count": mismatch_count,
		"would_change_count": would_change_count,
		"error_count": errors.size(),
		"errors": errors,
		"items": items,
	}

func _inspector_is_type_compatible(expected_type: int, value: Variant) -> bool:
	if expected_type == TYPE_NIL:
		return true
	if value == null:
		return expected_type == TYPE_OBJECT or expected_type == TYPE_NIL
	var value_type = typeof(value)
	if expected_type == TYPE_FLOAT and (value_type == TYPE_FLOAT or value_type == TYPE_INT):
		return true
	if expected_type == TYPE_INT and value_type == TYPE_INT:
		return true
	if expected_type == TYPE_INT and value_type == TYPE_FLOAT:
		var f = float(value)
		return floor(f) == f
	if expected_type == TYPE_STRING and value_type == TYPE_STRING_NAME:
		return true
	if expected_type == TYPE_STRING_NAME and value_type == TYPE_STRING:
		return true
	if expected_type == TYPE_OBJECT:
		return true
	return value_type == expected_type

func _screenshot_capture_from_viewport(viewport: Viewport, mode: String, params: Dictionary) -> Dictionary:
	if viewport == null:
		return _err(ERR_EDITOR_BUSY, "Viewport is not available")
	var texture = viewport.get_texture()
	if texture == null:
		return _err(ERR_EDITOR_BUSY, "Viewport texture is not available")
	var image = texture.get_image()
	if image == null:
		return _err(ERR_EDITOR_BUSY, "Failed to extract viewport image")
	if image.get_width() <= 0 or image.get_height() <= 0:
		return _err(ERR_EDITOR_BUSY, "Captured image is empty")

	var format = str(params.get("format", "png")).to_lower()
	if format == "jpeg":
		format = "jpg"
	if format != "png" and format != "jpg":
		return _err(RPC_INVALID_PARAMS, "Invalid format. Use png or jpg")
	var quality = clampf(float(params.get("jpg_quality", 0.85)), 0.0, 1.0)

	var capture_dir = "user://.godot_mcp/captures"
	var capture_dir_abs = ProjectSettings.globalize_path(capture_dir)
	var mk_err = DirAccess.make_dir_recursive_absolute(capture_dir_abs)
	if mk_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to create capture directory", {"error": mk_err, "path": capture_dir})

	var stamp = "%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_msec()]
	var save_path = "%s/%s_%s.%s" % [capture_dir, mode, stamp, format]
	var save_err = OK
	if format == "png":
		save_err = image.save_png(save_path)
	else:
		save_err = image.save_jpg(save_path, quality)
	if save_err != OK:
		return _err(ERR_EDITOR_BUSY, "Failed to save screenshot", {"error": save_err, "path": save_path})

	var bytes = FileAccess.get_file_as_bytes(save_path)
	var include_base64 = bool(params.get("include_base64", false))
	var max_base64_bytes = maxi(0, int(params.get("max_base64_bytes", 0)))
	var include_inline = include_base64 and (max_base64_bytes == 0 or bytes.size() <= max_base64_bytes)
	var payload = {
		"path": save_path,
		"format": format,
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": bytes.size(),
		"sha256": FileAccess.get_sha256(save_path),
		"captured_at": Time.get_datetime_string_from_system(),
		"base64_included": include_inline,
	}
	if include_inline:
		payload["base64"] = Marshalls.raw_to_base64(bytes)
	elif include_base64:
		payload["base64_omitted_reason"] = "Image exceeds max_base64_bytes"
	return _ok(payload)

func _normalize_runtime_log_level(level: String) -> String:
	match level.to_lower():
		"all":
			return "all"
		"error":
			return "error"
		"warning", "warn":
			return "warning"
		"info":
			return "info"
		_:
			return ""

func _normalize_capture_mode(mode: String) -> String:
	match mode.to_lower():
		"game":
			return "game"
		"editor":
			return "editor"
		_:
			return ""

func _normalize_capture_format(format: String) -> String:
	var normalized = format.to_lower()
	if normalized == "jpeg":
		normalized = "jpg"
	if normalized == "png" or normalized == "jpg":
		return normalized
	return ""

func _runtime_latest_log_path() -> String:
	var logs_dir = "user://logs"
	var dir = DirAccess.open(logs_dir)
	if dir == null:
		return ""
	var newest_path = ""
	var newest_time := -1
	for file_name in dir.get_files():
		var lower = str(file_name).to_lower()
		if not lower.ends_with(".log"):
			continue
		var candidate = logs_dir.path_join(str(file_name))
		var modified = int(FileAccess.get_modified_time(candidate))
		if modified >= newest_time:
			newest_time = modified
			newest_path = candidate
	return newest_path

func _parse_runtime_log_line(raw: String) -> Dictionary:
	var level = "info"
	if raw.find("ERROR:") != -1:
		level = "error"
	elif raw.find("WARNING:") != -1:
		level = "warning"
	var timestamp = ""
	if raw.begins_with("["):
		var end_idx = raw.find("]")
		if end_idx > 1:
			timestamp = raw.substr(1, end_idx - 1)
	return {
		"level": level,
		"timestamp": timestamp,
		"raw": raw,
	}

func _runtime_error_type(raw: String) -> String:
	var lower = raw.to_lower()
	if lower.find("parse error") != -1:
		return "parse_error"
	if lower.find("script error") != -1:
		return "script_error"
	if lower.find("error:") != -1:
		return "runtime_error"
	return ""

func _runtime_collect_error_summary(limit: int) -> Dictionary:
	var logs = _runtime_logs_tail({"limit": limit, "level": "all"})
	var parse_errors = _runtime_logs_parse_errors({"limit": limit})
	var runtime_log_errors := 0
	var runtime_log_warnings := 0
	var log_items = logs.get("data", {}).get("items", [])
	if typeof(log_items) == TYPE_ARRAY:
		for item in log_items:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var level = str(item.get("level", "info"))
			if level == "error":
				runtime_log_errors += 1
			elif level == "warning":
				runtime_log_warnings += 1
	var counts = {
		"runtime_log_errors": runtime_log_errors,
		"runtime_log_warnings": runtime_log_warnings,
		"parse_errors": int(parse_errors.get("data", {}).get("count", 0)),
		"bridge_errors": int(_state.snapshot().get("error_count", 0)),
		"bridge_warnings": int(_state.snapshot().get("warning_count", 0)),
	}
	return {
		"logs": logs.get("data", {}),
		"parse_errors": parse_errors.get("data", {}),
		"counts": counts,
	}

func _to_string_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			out.append(str(item))
	return out

func _path_has_any_extension(path: String, exts: Array[String]) -> bool:
	if exts.is_empty():
		return true
	var lower = path.to_lower()
	for ext in exts:
		var normalized = str(ext).to_lower()
		if normalized == "":
			continue
		if not normalized.begins_with("."):
			normalized = "." + normalized
		if lower.ends_with(normalized):
			return true
	return false

func _file_size_bytes(path: String) -> int:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	return int(file.get_length())

func _intent_methods_from_text(text: String) -> Array[String]:
	var lower = text.to_lower()
	var methods: Array[String] = []
	if lower.find("image") != -1 or lower.find("sprite") != -1 or lower.find("texture") != -1 or lower.find("asset") != -1:
		methods.append("assets.images.search")
		methods.append("assets.images.preview")
	if lower.find("error") != -1 or lower.find("debug") != -1 or lower.find("stack") != -1:
		methods.append("runtime.debugger.snapshot")
		methods.append("runtime.errors.delta")
	if lower.find("screenshot") != -1 or lower.find("capture") != -1 or lower.find("verify") != -1:
		methods.append("runtime.observe_after_play")
		methods.append("session.auto_capture.set")
	if lower.find("behavior") != -1 or lower.find("assert") != -1 or lower.find("verify") != -1 or lower.find("check") != -1:
		methods.append("runtime.behavior.check")
		methods.append("runtime.eval")
	if lower.find("inspect") != -1 or lower.find("runtime") != -1 or lower.find("live") != -1:
		methods.append("runtime.node.get_property")
		methods.append("runtime.ping_game")
	if lower.find("inspector") != -1 or lower.find("property") != -1:
		methods.append("inspector.values.patch_preview")
	if lower.find("node") != -1 or lower.find("scene") != -1:
		methods.append("node.add")
		methods.append("scene.open")
	if methods.is_empty():
		methods.append("editor.get_info")
		methods.append("capabilities.get")
	return methods

func _intent_template_for_method(method: String, context: Dictionary) -> Dictionary:
	if not _guard.is_allowed_method(method):
		return {}
	match method:
		"scene.open":
			return {"path": str(context.get("scene_path", "res://scenes/main.tscn"))}
		"node.add":
			return {
				"parent_path": str(context.get("parent_path", ".")),
				"type": str(context.get("type", "Node2D")),
				"name": str(context.get("name", "GeneratedNode")),
				"properties": context.get("properties", {}),
			}
		"script.create":
			return {
				"path": str(context.get("path", "res://scripts/generated_node.gd")),
				"template": str(context.get("template", "node")),
				"class_name": str(context.get("class_name", "GeneratedNodeScript")),
			}
		"script.attach":
			return {
				"node_path": str(context.get("node_path", ".")),
				"script_path": str(context.get("script_path", "res://scripts/generated_node.gd")),
			}
		"runtime.observe_after_play":
			return {
				"run_seconds": float(context.get("run_seconds", 1.0)),
				"log_limit": int(context.get("log_limit", 200)),
			}
		"runtime.ping_game":
			return {"timeout_ms": int(context.get("timeout_ms", 3000))}
		"runtime.eval":
			return {
				"expr": str(context.get("expr", "get_tree().root.get_child_count() > 0")),
				"timeout_ms": int(context.get("timeout_ms", 3000)),
			}
		"runtime.node.get_property":
			return {
				"node_path": str(context.get("node_path", "/root")),
				"property": str(context.get("property", "name")),
				"timeout_ms": int(context.get("timeout_ms", 3000)),
			}
		"runtime.behavior.check":
			return {
				"checks": context.get(
					"checks",
					[{"description": "Scene has nodes", "expr": "get_tree().root.get_child_count() > 0", "expected": true}],
				),
				"timeout_ms": int(context.get("timeout_ms", 3000)),
			}
		"runtime.debugger.snapshot":
			return {"limit": int(context.get("limit", 120))}
		"runtime.errors.delta":
			return {
				"baseline": str(context.get("baseline", "default")),
				"limit": int(context.get("limit", 200)),
				"update_baseline": bool(context.get("update_baseline", true)),
			}
		"assets.images.search":
			return {
				"query": str(context.get("query", "")),
				"root_path": str(context.get("root_path", "res://")),
				"limit": int(context.get("limit", 200)),
			}
		"assets.images.preview":
			return {"path": str(context.get("path", "res://icon.svg"))}
		"session.auto_capture.set":
			return {
				"enabled": bool(context.get("enabled", true)),
				"mode": str(context.get("mode", "game")),
				"format": str(context.get("format", "png")),
			}
		"inspector.values.patch_preview":
			return {
				"node_path": str(context.get("node_path", ".")),
				"patches": context.get("patches", [{"path": "process_priority", "value": 1}]),
				"atomic": bool(context.get("atomic", true)),
			}
		"editor.get_info":
			return {}
		"capabilities.get":
			return {}
		_:
			return {}

func _list_files_under(root_path: String, include_extensions: Array[String]) -> Array[String]:
	var entries: Array[Dictionary] = []
	_collect_dir_entries(root_path, true, true, false, entries)
	var files: Array[String] = []
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var file_path = str(entry.get("path", ""))
		if file_path == "":
			continue
		if _path_has_any_extension(file_path, include_extensions):
			files.append(file_path)
	return files

func _extract_dependency_res_path(raw_value: String) -> String:
	var text = raw_value.strip_edges()
	if text == "":
		return ""
	if text.begins_with("res://"):
		return text
	if text.find("::") != -1:
		var parts = text.split("::", false)
		for i in range(parts.size() - 1, -1, -1):
			var candidate = str(parts[i]).strip_edges()
			if candidate.begins_with("res://"):
				return candidate
	return ""

func _line_from_offset(text: String, offset: int) -> int:
	var target = clamp(offset, 0, text.length())
	return text.substr(0, target).count("\n") + 1

func _count_occurrences(text: String, token: String) -> int:
	if token == "":
		return 0
	var count := 0
	var at = text.find(token)
	while at != -1:
		count += 1
		at = text.find(token, at + token.length())
	return count

func _regex_escape_literal(text: String) -> String:
	var escaped = text
	var symbols: Array[String] = ["\\", ".", "+", "*", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|"]
	for symbol in symbols:
		escaped = escaped.replace(symbol, "\\" + symbol)
	return escaped

func _extract_res_paths_from_text(text: String) -> Array[String]:
	var regex = RegEx.new()
	regex.compile("res://[A-Za-z0-9_./\\-]+")
	var items: Dictionary = {}
	for match in regex.search_all(text):
		var value = match.get_string(0)
		if value != "":
			items[value] = true
	var out: Array[String] = []
	for key in items.keys():
		out.append(str(key))
	return out

func _organize_gdscript_methods(content: String) -> String:
	var lines = content.split("\n")
	if lines.is_empty():
		return content
	var method_start_indices: Array[int] = []
	var method_re = RegEx.new()
	method_re.compile("^\\s*(?:static\\s+)?func\\s+[A-Za-z_][A-Za-z0-9_]*\\s*\\(")
	for i in range(lines.size()):
		if method_re.search(str(lines[i])) != null:
			method_start_indices.append(i)
	if method_start_indices.size() <= 1:
		return content

	var prefix_lines = lines.slice(0, method_start_indices[0])
	var blocks: Array[Dictionary] = []
	for idx in range(method_start_indices.size()):
		var start = method_start_indices[idx]
		var finish = lines.size()
		if idx + 1 < method_start_indices.size():
			finish = method_start_indices[idx + 1]
		var block_lines = lines.slice(start, finish)
		var method_name = _extract_gd_method_name(str(lines[start]))
		blocks.append({"name": method_name, "lines": block_lines})
	blocks.sort_custom(
		func(a, b):
			return str(a.get("name", "")) < str(b.get("name", ""))
	)

	var rebuilt: Array[String] = []
	for line in prefix_lines:
		rebuilt.append(str(line))
	if rebuilt.size() > 0 and str(rebuilt[rebuilt.size() - 1]).strip_edges() != "":
		rebuilt.append("")
	for i in range(blocks.size()):
		var block_lines: Array = blocks[i].get("lines", [])
		for line in block_lines:
			rebuilt.append(str(line))
		if i < blocks.size() - 1:
			rebuilt.append("")
	return "\n".join(rebuilt)

func _extract_gd_method_name(signature_line: String) -> String:
	var regex = RegEx.new()
	regex.compile("^\\s*(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	var match = regex.search(signature_line)
	if match == null:
		return signature_line
	return match.get_string(1)

func _collect_dir_entries(path: String, recursive: bool, include_files: bool, include_dirs: bool, out_entries: Array[Dictionary]) -> void:
	var dir = DirAccess.open(path)
	if dir == null:
		return
	for directory in dir.get_directories():
		var full = path.path_join(directory)
		if include_dirs:
			out_entries.append({"type": "dir", "path": full})
		if recursive:
			_collect_dir_entries(full, true, include_files, include_dirs, out_entries)
	for file_name in dir.get_files():
		if include_files:
			out_entries.append({"type": "file", "path": path.path_join(file_name)})

func _collect_matching_files(path: String, pattern: String, out_matches: Array[Dictionary], max_results: int) -> void:
	if out_matches.size() >= max_results:
		return
	var dir = DirAccess.open(path)
	if dir == null:
		return
	for directory in dir.get_directories():
		if out_matches.size() >= max_results:
			return
		_collect_matching_files(path.path_join(directory), pattern, out_matches, max_results)
	for file_name in dir.get_files():
		if out_matches.size() >= max_results:
			return
		var full = path.path_join(file_name)
		var text = FileAccess.get_file_as_string(full)
		var index = text.find(pattern)
		if index != -1:
			out_matches.append({
				"path": full,
				"first_index": index,
			})

func _render_script_template(template: String, script_class: String) -> String:
	match template.to_lower():
		"characterbody2d":
			return "extends CharacterBody2D\n\nclass_name %s\n\n@export var speed: float = 240.0\n\nfunc _physics_process(_delta: float) -> void:\n\t# TODO: movement logic\n\tpass\n" % script_class
		"editorscript":
			return "@tool\nextends EditorScript\n\nclass_name %s\n\nfunc _run() -> void:\n\tprint(\"EditorScript ready\")\n" % script_class
		_:
			return "extends Node\n\nclass_name %s\n\nfunc _ready() -> void:\n\tpass\n" % script_class

func _write_text_file(path: String, content: String) -> Dictionary:
	var absolute = ProjectSettings.globalize_path(path)
	var dir_path = absolute.get_base_dir()
	var mk_err = DirAccess.make_dir_recursive_absolute(dir_path)
	if mk_err != OK:
		return {"ok": false, "error": "Failed to create directory"}

	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Failed to open file for writing"}
	file.store_string(content)
	return {"ok": true}

func _delete_res_file(path: String) -> int:
	var absolute = ProjectSettings.globalize_path(path)
	return DirAccess.remove_absolute(absolute)

func _encode_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return {"__type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"__type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"__type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Resource:
				return {"__type": "Resource", "path": value.resource_path, "class": value.get_class()}
			if value is Node:
				return {"__type": "Node", "path": str(value.get_path()), "class": value.get_class()}
			return str(value)
		_:
			return value

func _decode_value(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return value
	var t = str(value.get("__type", ""))
	match t:
		"Vector2":
			return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
		"Vector3":
			return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)))
		"Color":
			return Color(float(value.get("r", 0.0)), float(value.get("g", 0.0)), float(value.get("b", 0.0)), float(value.get("a", 1.0)))
		_:
			return value

func _rpc_ok(id: Variant, result: Variant) -> Dictionary:
	return {
		"jsonrpc": "2.0",
		"id": id,
		"result": result,
	}

func _rpc_error(id: Variant, code: int, message: String, data: Variant = null) -> Dictionary:
	var error_payload = {
		"code": code,
		"message": message,
	}
	if data != null:
		error_payload["data"] = data
	return {
		"jsonrpc": "2.0",
		"id": id,
		"error": error_payload,
	}

func _ok(data: Variant) -> Dictionary:
	return {"ok": true, "data": data}

func _err(code: int, message: String, data: Dictionary = {}) -> Dictionary:
	return {
		"ok": false,
		"code": code,
		"message": message,
		"data": data,
	}


