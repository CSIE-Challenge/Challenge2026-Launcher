extends Control

# --- Constants ---
const GITHUB_API := "http://ws3.csie.org:8080/repos/CSIE-Challenge/Challenge2026/releases/latest"
const GAME_NAME := "Challenge2026"
const PROXY_URL_PREFIX := "http://ws3.csie.org:8080/"

# --- State Variables ---
var base_dir: String
var save_dir: String
var agent_path: String
var agent_dir: String

var version: String
var executable_name: String
var executable_path: String
var asset_url := ""
var agent_url := ""
var asset_digest := ""
var agent_digest := ""

var game_downloaded := false
var extract_thread: Thread

# --- Progress State ---
var is_downloading := false
var is_extracting := false
var extraction_total := 0
var extraction_current := 0

# --- Nodes ---
@onready var loading_screen := $LoadingScreen
@onready var status_label := $LoadingScreen/Label
@onready var video_player := $LoadingScreen/VideoStreamPlayer
@onready var req := $HTTPRequest
@onready var progress_bar := $LoadingScreen/ProgressBar


# --- Lifecycle ---
func _ready() -> void:
	if progress_bar:
		progress_bar.visible = false

	if req:
		req.max_redirects = 0

	base_dir = _get_base_dir()
	if base_dir.is_empty():
		_log("Failed to initialize base directory.", "ERROR")
		return

	_log("Launcher started. Base directory: " + base_dir)

	save_dir = base_dir.path_join("GameBuilds")
	agent_path = base_dir.path_join("agent.zip")
	agent_dir = base_dir.path_join("agent")

	var dir := DirAccess.open(".")
	if not dir.dir_exists(save_dir):
		dir.make_dir_recursive(save_dir)
		_message("Created save directory: " + save_dir)

	_fetch_latest_release()


func _process(_delta: float) -> void:
	if not progress_bar:
		return

	if is_downloading and req:
		var body_size := req.get_body_size() as int
		var downloaded := req.get_downloaded_bytes() as int
		progress_bar.visible = true
		progress_bar.max_value = body_size if body_size > 0 else 100
		progress_bar.value = downloaded if body_size > 0 else 0
	elif is_extracting and extraction_total > 0:
		progress_bar.visible = true
		progress_bar.max_value = extraction_total
		progress_bar.value = extraction_current
	else:
		progress_bar.visible = false


# --- Main Flow: API & Updates ---
func _fetch_latest_release() -> void:
	_message("Checking for updates...")
	_log("Fetching release from reverse proxy: " + GITHUB_API)
	_request_api(GITHUB_API, _on_fetch_completed)


func _on_fetch_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_log_http_details("Fetch Release JSON", result, response_code, headers, body)

	if _handle_redirect(response_code, headers, _on_fetch_completed):
		return

	if response_code != 200:
		_log("Proxy API request failed. Response code: %d" % response_code, "ERROR")
		_handle_api_failure(response_code)
		return

	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("assets") or not data.has("tag_name"):
		_log("Failed to parse release data JSON from Proxy.", "ERROR")
		_message("Invalid release data")
		return

	version = data["tag_name"]
	executable_name = "%s_%s_%s" % [version, GAME_NAME, _get_platform_suffix()]
	executable_path = save_dir.path_join(executable_name)

	_log("Latest release tag: " + version)
	_log("Expected executable filename: " + executable_name)

	var agent_asset_name := _get_agent_asset_name()
	asset_url = ""
	agent_url = ""
	asset_digest = ""
	agent_digest = ""

	for asset in data["assets"]:
		var asset_name: String = asset["name"]
		if asset_name == agent_asset_name:
			agent_url = _to_proxy_url(asset["url"])
			agent_digest = asset.get("digest", "")
		elif asset_name == executable_name:
			asset_url = _to_proxy_url(asset["url"])
			asset_digest = asset.get("digest", "")

	if asset_url.is_empty():
		_log("No matching game executable asset found on remote: " + executable_name, "ERROR")
		_message("No matching asset found: " + executable_name)
		return

	if agent_url.is_empty():
		_log("No matching agent bundle found on remote.", "ERROR")
		_message("No agent bundle found in release assets.")
		return

	_check_local_executable()


func _check_local_executable() -> void:
	if FileAccess.file_exists(executable_path):
		_log("Local executable found. Verifying integrity...")
		if _verify_file_integrity(executable_path, asset_digest):
			_log("Integrity verified. Safe to skip download.")
			_message("You already have the latest version: " + version)

			if not asset_digest.is_empty():
				_save_local_hash(executable_path + ".sha256", asset_digest.trim_prefix("sha256:"))

			_ensure_agent_bundle()
			return
		else:
			_log("Integrity verification failed (File corrupted or outdated). Purging and re-downloading...", "WARN")
			DirAccess.remove_absolute(executable_path)

	var existing := _get_existing_executable_name()
	if not existing.is_empty() and existing != executable_name:
		_delete_existing_executable(existing)

	_download_executable()


func _handle_api_failure(response_code: int) -> void:
	is_downloading = false
	_log("Cannot check for new version (HTTP %d / Connection Error). Triggering offline fallback..." % response_code, "WARN")
	var existing := _get_existing_executable_name()

	if existing.is_empty():
		_log("Offline failure: No local game executable found at all.", "ERROR")
		_message("Offline error: No game installation found.")
		return

	var local_exec_path := save_dir.path_join(existing)
	var local_hash_path := local_exec_path + ".sha256"

	if FileAccess.file_exists(local_hash_path):
		var calc_hash := FileAccess.get_sha256(local_exec_path).to_lower()
		var exp_hash := _read_saved_hash(local_hash_path)
		_log("Offline Validation -> Calc: %s | Saved: %s" % [calc_hash, exp_hash])

		if not calc_hash.is_empty() and calc_hash == exp_hash:
			_log("Offline Hash verification PASSED for " + existing + ". Directly launching game!", "INFO")
			executable_name = existing
			executable_path = local_exec_path
			_ensure_agent_bundle()
			return
		else:
			_log("Offline Hash verification FAILED for " + existing + ". File corrupted.", "ERROR")
			_message("Game files are corrupted. Please reconnect to network to repair.")
	else:
		_log("No local .sha256 file found for " + existing + ". Cannot verify offline integrity.", "ERROR")
		_message("Cannot verify files offline. Internet connection required.")


# --- Main Flow: Downloading ---
func _download_executable() -> void:
	_log("Starting executable download from Proxy URL: " + asset_url)
	_message("Downloading latest version: " + executable_name)
	_request_download(asset_url, executable_path, _on_download_completed)


func _on_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_log_http_details("Download Executable", result, response_code, headers, body)

	if _handle_redirect(response_code, headers, _on_download_completed, executable_path):
		return

	is_downloading = false
	req.download_file = ""

	if response_code != 200:
		_log("Download failed with HTTP code: " + str(response_code), "ERROR")
		_message("Download failed: " + str(response_code))
		return

	_log("Download completed. Verifying integrity...")

	if not _verify_file_integrity(executable_path, asset_digest):
		_log("Downloaded file integrity check failed!", "ERROR")
		_message("Error: Downloaded file is corrupted. Please try again.")
		DirAccess.remove_absolute(executable_path)
		return

	if not asset_digest.is_empty():
		_save_local_hash(executable_path + ".sha256", asset_digest.trim_prefix("sha256:"))

	if OS.has_feature("macos"):
		_extract_macos_app(executable_path)

	game_downloaded = true
	_message("Download complete")
	_ensure_agent_bundle()


# --- Main Flow: Agent Bundle ---
func _ensure_agent_bundle() -> void:
	var have_bundle := FileAccess.file_exists(agent_dir.path_join("runner.py"))
	if have_bundle and not game_downloaded:
		_seed_player_agent()
		_launch_game()
		return
	_download_agent()


func _download_agent() -> void:
	_log("Downloading agent bundle from Proxy URL: " + agent_url)
	_message("Downloading agent bundle...")
	_request_download(agent_url, agent_path, _on_agent_downloaded)


func _on_agent_downloaded(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_log_http_details("Download Agent Bundle", result, response_code, headers, body)

	if _handle_redirect(response_code, headers, _on_agent_downloaded, agent_path):
		return

	is_downloading = false
	req.download_file = ""

	if response_code != 200:
		_log("Agent download failed with HTTP code: " + str(response_code), "ERROR")
		_message("Agent download failed: " + str(response_code))
		return

	if not _verify_file_integrity(agent_path, agent_digest):
		_log("Downloaded agent bundle integrity check failed!", "ERROR")
		_message("Error: Agent bundle is corrupted. Please try again.")
		DirAccess.remove_absolute(agent_path)
		return

	_log("Agent downloaded successfully. Starting worker thread for extraction.")
	_message("Extracting agent bundle...")

	is_extracting = true
	extract_thread = Thread.new()
	extract_thread.start(_extract_agent_bundle)


func _extract_agent_bundle() -> void:
	DirAccess.make_dir_recursive_absolute(agent_dir)
	_extract_all_from_zip(agent_path, agent_dir)
	DirAccess.remove_absolute(agent_path)

	if not OS.has_feature("windows"):
		OS.execute("chmod", ["-R", "+x", agent_dir.path_join("python/bin")])

	_on_agent_extracted.call_deferred()


func _on_agent_extracted() -> void:
	extract_thread.wait_to_finish()
	is_extracting = false
	_seed_player_agent()
	_log("Agent bundle extraction and seeding ready.")
	_message("Agent bundle ready")
	_launch_game()


func _seed_player_agent() -> void:
	var target := agent_dir.path_join("scripts/agent.py")
	if FileAccess.file_exists(target):
		return

	DirAccess.make_dir_recursive_absolute(agent_dir.path_join("scripts"))
	DirAccess.copy_absolute(agent_dir.path_join("agent.py"), target)
	_message("Created starter agent script: " + target)


func _extract_all_from_zip(path: String, to: String) -> void:
	var reader := ZIPReader.new()
	reader.open(path)
	var files := reader.get_files()

	extraction_total = files.size()
	extraction_current = 0

	var root := DirAccess.open(to)
	for file_path in files:
		if file_path.ends_with("/"):
			root.make_dir_recursive(file_path)
			extraction_current += 1
			continue

		root.make_dir_recursive(root.get_current_dir().path_join(file_path).get_base_dir())
		var f := FileAccess.open(root.get_current_dir().path_join(file_path), FileAccess.WRITE)
		if f:
			f.store_buffer(reader.read_file(file_path))
			f.close()
		extraction_current += 1


# --- Main Flow: Launch Game ---
func _launch_game() -> void:
	var app_path := executable_path
	if OS.has_feature("macos"):
		app_path = save_dir.path_join("%s.app/Contents/MacOS/%s" % [GAME_NAME, GAME_NAME])
		if not FileAccess.file_exists(app_path) and FileAccess.file_exists(executable_path):
			_extract_macos_app(executable_path)

	if not FileAccess.file_exists(app_path):
		_log("Game executable not found at path: " + app_path, "ERROR")
		_message("Game executable not found at: " + app_path)
		return

	if OS.has_feature("macos"):
		OS.execute("xattr", ["-rd", "com.apple.quarantine", app_path])
	elif OS.has_feature("linux"):
		OS.execute("chmod", ["+x", app_path])

	var args := ["--quiet", "--", "--agent-bundle", agent_dir]
	_log("Executing game process: " + app_path)
	var pid := OS.create_process(app_path, args, true)

	_message("Game launched (pid %d). Closing launcher..." % pid)
	await get_tree().create_timer(1.5).timeout
	get_tree().quit()


# --- HTTP Utilities ---
func _request_api(url: String, callback: Callable) -> void:
	_connect_req_signal(callback)
	var headers := ["User-Agent: Challenge2026-Launcher-App"]
	var err := req.request(url, headers) as Error
	if err != OK:
		_log("Failed to send request to Proxy API. Error code: " + str(err), "ERROR")
		_handle_api_failure(-1)


func _request_download(url: String, download_path: String, callback: Callable) -> void:
	is_downloading = true
	req.download_file = download_path
	_connect_req_signal(callback)
	var headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
	req.request(url, headers)


func _handle_redirect(response_code: int, headers: PackedStringArray, callback: Callable, download_path: String = "") -> bool:
	if response_code in [301, 302, 303, 307, 308]:
		var redir_url := _parse_redirect_url(headers)
		if not redir_url.is_empty():
			_log("Redirecting via Proxy -> " + redir_url, "INFO")
			if download_path.is_empty():
				_request_api(redir_url, callback)
			else:
				_request_download(redir_url, download_path, callback)
			return true
	return false


func _to_proxy_url(raw_url: String) -> String:
	if raw_url.is_empty():
		return ""

	var clean_url := raw_url
	var proxy_targets := [
		"https://api.github.com/",
		"https://objects.githubusercontent.com/",
		"https://release-assets.githubusercontent.com/",
        "https://github.com/"
	]

	for target in proxy_targets:
		if clean_url.begins_with(target):
			clean_url = clean_url.replace(target, PROXY_URL_PREFIX)
			break

	_log("URL Rewritten: %s -> %s" % [raw_url, clean_url], "DEBUG")
	return clean_url


func _parse_redirect_url(headers: PackedStringArray) -> String:
	for header in headers:
		if header.to_lower().begins_with("location:"):
			var raw_loc := header.split(":", false, 1)[1].strip_edges()
			return _to_proxy_url(raw_loc)
	return ""


func _connect_req_signal(target: Callable) -> void:
	for conn in req.request_completed.get_connections():
		req.request_completed.disconnect(conn["callable"])
	req.request_completed.connect(target)


# --- File/Hash Utilities ---
func _verify_file_integrity(file_path: String, remote_digest: String) -> bool:
	if remote_digest.is_empty():
		_log("No remote checksum provided, skipping integrity check.", "WARN")
		return true

	var expected_hash := remote_digest.to_lower().trim_prefix("sha256:")

	if not FileAccess.file_exists(file_path):
		_log("Local file does not exist, verification failed: " + file_path, "DEBUG")
		return false

	_log("Calculating SHA256 of local file... (%s)" % file_path, "INFO")

	var local_hash := FileAccess.get_sha256(file_path).to_lower()

	_log("Local hash: " + local_hash, "DEBUG")
	_log("Expected hash: " + expected_hash, "DEBUG")

	if local_hash == expected_hash:
		_log("[Integrity Verification Passed] File is intact!", "INFO")
		return true
	else:
		_log("[WARNING] Integrity verification failed! File may be corrupted or tampered with.", "ERROR")
		return false


func _read_saved_hash(hash_path: String) -> String:
	if not FileAccess.file_exists(hash_path):
		return ""
	var f := FileAccess.open(hash_path, FileAccess.READ)
	if not f:
		return ""
	var content := f.get_as_text().strip_edges()
	f.close()

	if content.is_empty(): return ""
	return content.split(" ")[0].to_lower()


func _save_local_hash(hash_path: String, hash_val: String) -> void:
	var f := FileAccess.open(hash_path, FileAccess.WRITE)
	if f:
		f.store_string(hash_val.to_lower())
		f.close()


func _extract_macos_app(zip_path: String) -> void:
	_log("Extracting macOS App bundle...")
	var target_app := save_dir.path_join(GAME_NAME + ".app")
	OS.execute("rm", ["-rf", target_app])
	OS.execute("unzip", ["-o", zip_path, "-d", base_dir])
	OS.execute("mv", [base_dir.path_join(GAME_NAME + ".app"), save_dir])


# --- System Utilities ---
func _get_base_dir() -> String:
	var exec_path := OS.get_executable_path()
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	if OS.has_feature("macos") and ".app/Contents/MacOS" in exec_path:
		if "AppTranslocation" in exec_path:
			_message("ERROR: macOS has moved this app to a temporary read-only location.\nMove Launcher.app to /Applications (or ~/Applications) and open it from there.")
			return ""
		return exec_path.get_base_dir().get_base_dir().path_join("Resources")
	return exec_path.get_base_dir()


func _get_platform_suffix() -> String:
	if OS.has_feature("windows"): return "windows.exe"
	elif OS.has_feature("linux"): return "linux.x86_64"
	elif OS.has_feature("macos"): return "macos.zip"
	return ""


func _get_agent_asset_name() -> String:
	var os_label := ""
	if OS.has_feature("windows"): os_label = "windows"
	elif OS.has_feature("linux"): os_label = "linux"
	elif OS.has_feature("macos"): os_label = "macos"
	else: return ""

	var arch := ""
	if OS.has_feature("arm64") or (OS.has_feature("macos") and OS.has_feature("x86_64")):
		arch = "aarch64"
	elif OS.has_feature("x86_64"):
		arch = "x86_64"
	else: return ""

	return "agent-%s-%s.zip" % [os_label, arch]


func _get_existing_executable_name() -> String:
	var dir := DirAccess.open(save_dir)
	if dir == null: return ""

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var platform_suffix := _get_platform_suffix()

	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(platform_suffix):
			return file_name
		file_name = dir.get_next()

	dir.list_dir_end()
	return ""


func _delete_existing_executable(file_name: String) -> void:
	var full_path := save_dir.path_join(file_name)
	if FileAccess.file_exists(full_path):
		DirAccess.remove_absolute(full_path)
		_message("Deleted old version: " + file_name)

	var hash_path := full_path + ".sha256"
	if FileAccess.file_exists(hash_path):
		DirAccess.remove_absolute(hash_path)


# --- Logging & UI ---
func _log_http_details(stage: String, result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	# Only log HTTP details when the status code is NOT 200
	if response_code == 200:
		return

	var level := "INFO" if response_code in [301, 302, 303, 307, 308] else "ERROR"
	_log("=== [HTTP Response Log: %s] ===" % stage, level)
	_log(" > Godot Internal Result: %s (%d)" % [_get_result_string(result), result], level)
	_log(" > HTTP Status Code: %d" % response_code, level)

	_log(" --- Response Headers Dump ---", "DEBUG")
	for h in headers:
		_log("   [Header] " + h, "DEBUG")

	if not (response_code in [301, 302, 303, 307, 308]):
		_log(" --- Error Body Snippet ---", "WARN")
		if body.size() > 0:
			var body_str := body.get_string_from_utf8().strip_edges()
			if body_str.is_empty():
				body_str = body.get_string_from_ascii().strip_edges()
			if body_str.length() > 250:
				body_str = body_str.substr(0, 250) + "... [Truncated]"
			_log(body_str, "WARN")
		else:
			_log("[Response body is totally empty]", "WARN")
	_log("==================================================", level)


func _log(message: String, level: String = "INFO") -> void:
	var time_str := Time.get_datetime_string_from_system()
	var log_line := "[%s] [%s] %s" % [time_str, level, message]

	print(log_line)
	if level == "ERROR":
		push_error(log_line)

	var log_path := "user://launcher_debug.log"
	if not base_dir.is_empty():
		log_path = base_dir.path_join("launcher_debug.log")

	var file := FileAccess.open(log_path, FileAccess.READ_WRITE if FileAccess.file_exists(log_path) else FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(log_line)
		file.close()


func _message(message: String) -> void:
	status_label.text = message
	_log(message, "INFO")


func _get_result_string(result: int) -> String:
	var results := {
		0: "RESULT_SUCCESS",
		1: "RESULT_CHUNKED_BODY_SIZE_MISMATCH",
		2: "RESULT_CANT_CONNECT",
		3: "RESULT_CANT_RESOLVE",
		4: "RESULT_CONNECTION_ERROR",
		5: "RESULT_SSL_HANDSHAKE_ERROR",
		6: "RESULT_NO_RESPONSE",
		7: "RESULT_BODY_SIZE_LIMIT_EXCEEDED",
		8: "RESULT_REQUEST_FILE_CANT_OPEN",
		9: "RESULT_REQUEST_FILE_CANT_WRITE",
		10: "RESULT_REDIRECT_LIMIT_EXCEEDED",
		11: "RESULT_TIMEOUT"
	}
	return results.get(result, "UNKNOWN_ERROR")


# --- Signals ---
func _on_exit_pressed() -> void:
	get_tree().quit()
