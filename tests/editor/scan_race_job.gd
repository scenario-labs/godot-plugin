extends "res://addons/agentkit/agent_job.gd"
## Editor regression test: a result written while the editor is already
## scanning still imports quickly. EditorFileSystem.scan() is dropped during a
## scan, and the scan in progress may never see a folder created after it began.

const Placer := preload("res://addons/scenario/editor/placer.gd")


func run() -> Dictionary:
	await wait_frames(3)
	var fs := EditorInterface.get_resource_filesystem()
	var run_dir := "res://tests/tmp_output/scan-race-%d/image" % Time.get_ticks_usec()
	# Start a scan and catch it running: the plugin's own scan() is then dropped.
	fs.scan()
	var waited := 0
	while not fs.is_scanning() and waited < 600:
		await root.get_tree().process_frame
		waited += 1
	var was_scanning := fs.is_scanning()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var path := run_dir + "/result.png"
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.6, 0.9))
	image.save_png(ProjectSettings.globalize_path(path))
	var started := Time.get_ticks_msec()
	await Placer.new().import_files("image", [{"path": path, "role": "main"}])
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	var imported := Placer.is_imported(path)
	var ok := imported and seconds < 20.0
	return {"ok": ok, "checks": 1, "failures": [] if ok else ["import while the editor scans"], "paid_calls": 0,
			"was_scanning": was_scanning, "imported": imported, "seconds": seconds}
