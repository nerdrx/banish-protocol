extends SceneTree
## HDR OUTPUT CAPABILITY PROBE (Godot 4.7 feature) — reports, never assumes.
##
##   tools/fidelity_bench/hdr_probe.sh            # SDR baseline, under gamescope
##   tools/fidelity_bench/hdr_probe.sh --hdr      # gamescope --hdr-enabled
##
## Godot 4.7 exposes a real HDR output path on Linux:
##   display/window/hdr/request_hdr_output   (project setting, off by default)
##   DisplayServer.window_is_hdr_output_supported()
##   DisplayServer.window_request_hdr_output()
##   DisplayServer.window_is_hdr_output_enabled()
##   ..._reference_luminance / ..._max_luminance   (SDR white point, peak nits)
##
## The distinction that matters and that a one-line "is HDR on?" check misses:
##
##   SUPPORTED  the swapchain surface can be created in an HDR colour space.
##              This is a property of the WINDOWING SYSTEM the process is
##              talking to, not of the monitor. A headless gamescope reports
##              whatever gamescope was started with, which is why this probe is
##              only meaningful when you also say which wrapper it ran under.
##   REQUESTED  we asked. Always readable.
##   ENABLED    the compositor actually gave it to us and the chain is live.
##
## Only ENABLED means anything is happening. SUPPORTED without ENABLED usually
## means the compositor advertises the colour-management protocol but the
## specific output is in SDR mode.
##
## This probe deliberately prints raw values and no verdict. A verdict from a
## nested compositor about a monitor it is not connected to would be a lie.

func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var win: int = DisplayServer.MAIN_WINDOW_ID
	print("[HDR] ---- environment ----")
	print("[HDR] display server      : %s" % DisplayServer.get_name())
	print("[HDR] XDG_SESSION_TYPE    : %s" % OS.get_environment("XDG_SESSION_TYPE"))
	print("[HDR] WAYLAND_DISPLAY     : '%s'" % OS.get_environment("WAYLAND_DISPLAY"))
	print("[HDR] DISPLAY             : '%s'" % OS.get_environment("DISPLAY"))
	print("[HDR] video adapter       : %s (%s)" % [
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_vendor()])
	print("[HDR] driver              : %s" % RenderingServer.get_video_adapter_api_version())

	print("[HDR] ---- project settings ----")
	print("[HDR] request_hdr_output  : %s" % str(
			ProjectSettings.get_setting("display/window/hdr/request_hdr_output", false)))
	print("[HDR] hdr_2d              : %s" % str(
			ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)))

	print("[HDR] ---- before request ----")
	print("[HDR] supported           : %s" % str(
			DisplayServer.window_is_hdr_output_supported(win)))
	print("[HDR] requested           : %s" % str(
			DisplayServer.window_is_hdr_output_requested(win)))
	print("[HDR] enabled             : %s" % str(
			DisplayServer.window_is_hdr_output_enabled(win)))

	DisplayServer.window_request_hdr_output(true, win)
	# Give the swapchain a few frames to be torn down and rebuilt in the new
	# colour space — the flag does not flip on the same frame it is set.
	for _i in 30:
		await process_frame

	print("[HDR] ---- after request ----")
	print("[HDR] supported           : %s" % str(
			DisplayServer.window_is_hdr_output_supported(win)))
	print("[HDR] requested           : %s" % str(
			DisplayServer.window_is_hdr_output_requested(win)))
	print("[HDR] enabled             : %s" % str(
			DisplayServer.window_is_hdr_output_enabled(win)))
	print("[HDR] ref luminance       : set=%.1f current=%.1f nits" % [
		DisplayServer.window_get_hdr_output_reference_luminance(win),
		DisplayServer.window_get_hdr_output_current_reference_luminance(win)])
	print("[HDR] max luminance       : set=%.1f current=%.1f nits" % [
		DisplayServer.window_get_hdr_output_max_luminance(win),
		DisplayServer.window_get_hdr_output_current_max_luminance(win)])
	print("[HDR] ----------------------")
	quit(0)
