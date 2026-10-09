@tool
extends EditorPlugin

# Tells Godot's Android export to include the HandTracker plugin (built by GitHub Actions into bin/)
# and the libraries it needs.
var export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(export_plugin)
	export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "HandTracker"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray([PLUGIN_NAME + "/bin/" + PLUGIN_NAME + "-release.aar"])

	func _get_android_dependencies(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray([
			"com.google.mediapipe:tasks-vision:0.10.14",
			"androidx.camera:camera-camera2:1.3.4",
			"androidx.camera:camera-lifecycle:1.3.4",
		])

	func _get_name() -> String:
		return PLUGIN_NAME
