extends Control

# 核心設定
const GITHUB_API := "http://ws3.csie.org:8080/repos/CSIE-Challenge/Challenge2026/releases/latest"
const GAME_NAME := "Challenge2026"
const PROXY_URL_PREFIX := "http://ws3.csie.org:8080/"

var base_dir: String
var save_dir: String
var agent_path: String
var agent_dir: String

var videos: Array[VideoStream] = [
	preload("res://Videos/yuanshou.ogv"),
	preload("res://Videos/catlaugh.ogv"),
	preload("res://Videos/catbonk.ogv"),
	preload("res://Videos/chipichapa.ogv"),
	preload("res://Videos/cathuh.ogv"),
	preload("res://Videos/catdance.ogv"),
	preload("res://Videos/catscream.ogv")
]
var last_index := -1
var version: String
var executable_name: String
var executable_path: String
var asset_url := ""
var agent_url := ""
var hash_url := "" 
var game_downloaded := false
var extract_thread: Thread

# 進度條控制變數
var is_downloading := false
var is_extracting := false
var extraction_total := 0
var extraction_current := 0

@onready var loading_screen := $LoadingScreen
@onready var status_label := $LoadingScreen/Label
@onready var video_player := $LoadingScreen/VideoStreamPlayer
@onready var req := $HTTPRequest
@onready var progress_bar := $LoadingScreen/ProgressBar


func _process(_delta: float) -> void:
	if is_downloading and req:
		var body_size = req.get_body_size()
		var downloaded = req.get_downloaded_bytes()
		if body_size > 0:
			progress_bar.visible = true
			progress_bar.max_value = body_size
			progress_bar.value = downloaded
		else:
			progress_bar.visible = true
			progress_bar.max_value = 100
			progress_bar.value = 0
	elif is_extracting:
		if extraction_total > 0:
			progress_bar.visible = true
			progress_bar.max_value = extraction_total
			progress_bar.value = extraction_current
	else:
		if progress_bar and progress_bar.visible:
			progress_bar.visible = false


# 精準將不同網域對應到 Nginx 的分流路徑
func _to_proxy_url(raw_url: String) -> String:
	if raw_url.is_empty():
		return ""
	var clean_url = raw_url
	
	if clean_url.begins_with("https://api.github.com/"):
		clean_url = clean_url.replace("https://api.github.com/", PROXY_URL_PREFIX)
		
	elif clean_url.begins_with("https://objects.githubusercontent.com/"):
		clean_url = clean_url.replace("https://objects.githubusercontent.com/", PROXY_URL_PREFIX)
		
	elif clean_url.begins_with("https://release-assets.githubusercontent.com/"):
		clean_url = clean_url.replace("https://release-assets.githubusercontent.com/", PROXY_URL_PREFIX)
		
	elif clean_url.begins_with("https://github.com/"):
		clean_url = clean_url.replace("https://github.com/", PROXY_URL_PREFIX)
		
	_log("URL Rewritten: %s -> %s" % [raw_url, clean_url], "DEBUG")
	return clean_url


# --- 增加：進階 HTTP 詳細錯誤紀錄系統 ---
func _log_http_details(stage: String, result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
	_log("=== [HTTP Response Log: %s] ===" % stage, "INFO" if result == OK and response_code in [200, 302] else "ERROR")
	_log(" > Godot Internal Result: %s (%d)" % [_get_result_string(result), result], "INFO" if result == OK else "ERROR")
	_log(" > HTTP Status Code: %d" % response_code, "INFO" if response_code in [200, 302] else "ERROR")
	
	_log(" --- Response Headers Dump ---", "DEBUG")
	for h in headers:
		_log("   [Header] " + h, "DEBUG")
		
	if response_code != 200 and response_code != 302 and response_code != 301:
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
	_log("==================================================", "INFO")


# 從 Headers 中解析並重寫 Redirect Location 網址
func _parse_redirect_url(headers: PackedStringArray) -> String:
	for header in headers:
		if header.to_lower().begins_with("location:"):
			var raw_loc = header.split(":", false, 1)[1].strip_edges()
			return _to_proxy_url(raw_loc)
	return ""


# --- Log 紀錄系統 ---
func _log(message: String, level: String = "INFO"):
	var time_str := Time.get_datetime_string_from_system()
	var log_line := "[%s] [%s] %s" % [time_str, level, message]
	
	print(log_line)
	if level == "ERROR":
		push_error(log_line)
	
	var log_path := "user://launcher_debug.log"
	if base_dir != "":
		log_path = base_dir + "/launcher_debug.log"
		
	var file = FileAccess.open(log_path, FileAccess.READ_WRITE if FileAccess.file_exists(log_path) else FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(log_line)
		file.close()


func _message(message: String):
	status_label.text = message
	_log(message, "INFO")


func _get_base_dir() -> String:
	var exec_path := OS.get_executable_path()
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	if OS.has_feature("macos") and ".app/Contents/MacOS" in exec_path:
		if "AppTranslocation" in exec_path:
			_message("ERROR: macOS has moved this app to a temporary read-only location.\nMove Launcher.app to /Applications (or ~/Applications) and open it from there.")
			return ""
		return exec_path.get_base_dir().get_base_dir() + "/Resources"
	return exec_path.get_base_dir()


func _ready():
	if progress_bar:
		progress_bar.visible = false 
		
	# 強制將自動重定向歸零，改由我們的程式手動過濾與捕捉，確保重定向流量百分之百不脫離 Proxy
	if req:
		req.max_redirects = 0
		
	video_player.size = get_viewport_rect().size
	video_player.finished.connect(_play_random_video)
	_play_random_video()
	loading_screen.visible = true

	base_dir = _get_base_dir()
	if base_dir == "":
		_log("Failed to initialize base directory.", "ERROR")
		return

	_log("Launcher started. Base directory: " + base_dir)

	save_dir = base_dir + "/GameBuilds"
	agent_path = base_dir + "/agent.zip"
	agent_dir = base_dir + "/agent"

	var dir := DirAccess.open(".")
	if not dir.dir_exists(save_dir):
		dir.make_dir_recursive(save_dir)
		_message("Created save directory: " + save_dir)

	_fetch_latest_release()


func _play_random_video():
	if videos.is_empty():
		return
	var index := randi() % videos.size()
	if videos.size() > 1:
		while index == last_index:
			index = randi() % videos.size()
	last_index = index
	video_player.stream = videos[index]
	video_player.play()


func _get_platform_suffix() -> String:
	if OS.has_feature("windows"):
		return "windows.exe"
	if OS.has_feature("linux"):
		return "linux.x86_64"
	if OS.has_feature("macos"):
		return "macos.zip"
	return ""


func _get_agent_asset_name() -> String:
	var os_label := ""
	if OS.has_feature("windows"):
		os_label = "windows"
	elif OS.has_feature("linux"):
		os_label = "linux"
	elif OS.has_feature("macos"):
		os_label = "macos"
	else:
		return ""

	var arch := ""
	if OS.has_feature("arm64"):
		arch = "aarch64"
	elif OS.has_feature("x86_64"):
		if OS.has_feature("macos"):
			arch = "aarch64"
		else:
			arch = "x86_64"
	else:
		return ""

	return "agent-%s-%s.zip" % [os_label, arch]


func _get_existing_executable_name() -> String:
	var dir := DirAccess.open(save_dir)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(_get_platform_suffix()):
			return file_name
		file_name = dir.get_next()
	dir.list_dir_end()
	return ""


func _delete_existing_executable(file_name: String):
	var full_path = save_dir + "/" + file_name
	if FileAccess.file_exists(full_path):
		DirAccess.remove_absolute(full_path)
		_message("Deleted old version: " + file_name)
	var hash_path = full_path + ".sha256"
	if FileAccess.file_exists(hash_path):
		DirAccess.remove_absolute(hash_path)


func _fetch_latest_release():
	_message("Checking for updates...")
	_connect_req_signal(_on_fetch_completed)
	
	_log("Fetching release from reverse proxy: " + GITHUB_API)
	var headers := ["User-Agent: Challenge2026-Launcher-App"]
	var err = req.request(GITHUB_API, headers)
	if err != OK:
		_log("Failed to send request to Proxy API. Error code: " + str(err), "ERROR")
		_handle_api_failure(-1)


func _on_fetch_completed(result, response_code, headers, body):
	_log_http_details("Fetch Release JSON", result, response_code, headers, body)
	
	# 手動捕捉並重導向 302 流量至 Proxy
	if response_code in [301, 302, 303, 307, 308]:
		var redir_url = _parse_redirect_url(headers)
		if not redir_url.is_empty():
			_log("Redirecting Fetch Release JSON via Proxy -> " + redir_url, "INFO")
			_connect_req_signal(_on_fetch_completed)
			req.request(redir_url, ["User-Agent: Challenge2026-Launcher-App"])
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

	var tag = data["tag_name"]
	version = tag
	executable_name = "%s_%s_%s" % [version, GAME_NAME, _get_platform_suffix()]
	executable_path = "%s/%s" % [save_dir, executable_name]

	_log("Latest release tag: " + version)
	_log("Expected executable filename: " + executable_name)

	var agent_asset_name := _get_agent_asset_name()
	var hash_asset_name := executable_name + ".sha256"
	
	asset_url = ""
	agent_url = ""
	hash_url = ""

	for asset in data["assets"]:
		var asset_name = asset["name"]
		if asset_name == agent_asset_name:
			agent_url = _to_proxy_url(asset["url"])
		elif asset_name == executable_name:
			asset_url = _to_proxy_url(asset["url"])
		elif asset_name == hash_asset_name:
			hash_url = _to_proxy_url(asset["url"])

	if asset_url == "":
		_log("No matching game executable asset found on remote: " + executable_name, "ERROR")
		_message("No matching asset found: " + executable_name)
		return

	if agent_url == "":
		_log("No matching agent bundle found on remote.", "ERROR")
		_message("No agent bundle found in release assets.")
		return

	if hash_url != "":
		_log("Remote hash asset found. Downloading hash file via Proxy...")
		_download_hash_file()
	else:
		_log("No remote hash file found. Falling back to robust local integrity check.", "WARN")
		_process_version_check_without_remote_hash()


# --- 核心 Hash 驗證與手動重導向邏輯 ---

func _download_hash_file():
	is_downloading = true 
	req.download_file = executable_path + ".sha256"
	_connect_req_signal(_on_hash_file_completed)
	var headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
	req.request(hash_url, headers)


func _on_hash_file_completed(result, response_code, headers, body):
	_log_http_details("Download Hash File", result, response_code, headers, body)
	
	# 手動捕捉並重導向 Hash 檔案的 302 流量至 Proxy
	if response_code in [301, 302, 303, 307, 308]:
		var redir_url = _parse_redirect_url(headers)
		if not redir_url.is_empty():
			_log("Redirecting Hash File download via Proxy -> " + redir_url, "INFO")
			_connect_req_signal(_on_hash_file_completed)
			req.download_file = executable_path + ".sha256"
			var h_headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
			req.request(redir_url, h_headers)
			return

	is_downloading = false 
	req.download_file = "" 
	if response_code != 200:
		_log("Failed to download remote hash file. Code: " + str(response_code), "WARN")
		_process_version_check_without_remote_hash()
		return
	_verify_hash_and_proceed()


func _verify_hash_and_proceed():
	var local_exists = FileAccess.file_exists(executable_path)
	var hash_passed = false
	
	if local_exists:
		var calc_hash = _get_file_sha256(executable_path)
		var exp_hash = _read_saved_hash(executable_path + ".sha256")
		_log("Online Validation -> Calc: %s | Expected: %s" % [calc_hash, exp_hash])
		if calc_hash != "" and calc_hash == exp_hash:
			hash_passed = true
			
	if hash_passed:
		_log("Hash verification PASSED. Executable is intact and up-to-date.")
		_message("You already have the latest version: " + version)
		_ensure_agent_bundle()
	else:
		if local_exists:
			_log("Hash verification FAILED (File corrupted or outdated). Re-downloading...", "WARN")
			DirAccess.remove_absolute(executable_path)
		else:
			_log("Local executable missing. Starting download...")
		_download_executable()


func _process_version_check_without_remote_hash():
	var existing = _get_existing_executable_name()
	if existing == executable_name:
		var local_hash_path = executable_path + ".sha256"
		if FileAccess.file_exists(local_hash_path):
			var calc_hash = _get_file_sha256(executable_path)
			var saved_hash = _read_saved_hash(local_hash_path)
			if calc_hash != "" and calc_hash == saved_hash:
				_log("Local filename matches and local hash is verified. Safe to skip download.")
				_message("You already have the latest version: " + version)
				_ensure_agent_bundle()
				return
		
		_log("Local file found but integrity verification failed. Purging and re-downloading...", "WARN")
		DirAccess.remove_absolute(executable_path)
		if FileAccess.file_exists(local_hash_path):
			DirAccess.remove_absolute(local_hash_path)
		_download_executable()
	else:
		if existing != "":
			_delete_existing_executable(existing)
		_download_executable()


func _handle_api_failure(response_code: int):
	is_downloading = false
	_log("Cannot check for new version (HTTP %d / Connection Error). Triggering offline fallback..." % response_code, "WARN")
	var existing = _get_existing_executable_name()
	
	if existing == "":
		_log("Offline failure: No local game executable found at all.", "ERROR")
		_message("Offline error: No game installation found.")
		return
		
	var local_exec_path = save_dir + "/" + existing
	var local_hash_path = local_exec_path + ".sha256"
	
	if FileAccess.file_exists(local_hash_path):
		var calc_hash = _get_file_sha256(local_exec_path)
		var exp_hash = _read_saved_hash(local_hash_path)
		_log("Offline Validation -> Calc: %s | Saved: %s" % [calc_hash, exp_hash])
		
		if calc_hash != "" and calc_hash == exp_hash:
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


func _download_executable():
	_log("Starting executable download from Proxy URL: " + asset_url)
	_message("Downloading latest version: " + executable_name)
	is_downloading = true 
	req.download_file = executable_path
	_connect_req_signal(_on_download_completed)
	var headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
	req.request(asset_url, headers)


func _on_download_completed(result, response_code, headers, body):
	_log_http_details("Download Executable", result, response_code, headers, body)
	
	# 手動捕捉並重導向 主程式 的 302 流量至 Proxy
	if response_code in [301, 302, 303, 307, 308]:
		var redir_url = _parse_redirect_url(headers)
		if not redir_url.is_empty():
			_log("Redirecting Executable download via Proxy -> " + redir_url, "INFO")
			_connect_req_signal(_on_download_completed)
			req.download_file = executable_path
			var h_headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
			req.request(redir_url, h_headers)
			return

	is_downloading = false 
	req.download_file = ""
	if response_code != 200:
		_log("Download failed with HTTP code: " + str(response_code), "ERROR")
		_message("Download failed: " + str(response_code))
		return

	_log("Download completed. Saving local integrity hash...")
	var calc_hash = _get_file_sha256(executable_path)
	_save_local_hash(executable_path + ".sha256", calc_hash)

	if OS.has_feature("macos"):
		_log("Extracting macOS App bundle...")
		OS.execute("rm", ["-rf", save_dir + "/" + GAME_NAME + ".app"])
		OS.execute("unzip", ["-o", executable_path, "-d", base_dir])
		OS.execute("mv", [base_dir + "/" + GAME_NAME + ".app", save_dir])

	game_downloaded = true
	_message("Download complete")
	_ensure_agent_bundle()


# --- agent bundle -----------------------------------------------------------


func _ensure_agent_bundle():
	var have_bundle := FileAccess.file_exists(agent_dir + "/runner.py")
	if have_bundle and not game_downloaded:
		_seed_player_agent()
		_launch_game()
		return
	_download_agent()


func _download_agent():
	_log("Downloading agent bundle from Proxy URL: " + agent_url)
	_message("Downloading agent bundle...")
	is_downloading = true 
	req.download_file = agent_path
	_connect_req_signal(_on_agent_downloaded)
	var headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
	req.request(agent_url, headers)


func _on_agent_downloaded(result, response_code, headers, body):
	_log_http_details("Download Agent Bundle", result, response_code, headers, body)
	
	# 手動捕捉並重導向 Agent 的 302 流量至 Proxy
	if response_code in [301, 302, 303, 307, 308]:
		var redir_url = _parse_redirect_url(headers)
		if not redir_url.is_empty():
			_log("Redirecting Agent download via Proxy -> " + redir_url, "INFO")
			_connect_req_signal(_on_agent_downloaded)
			req.download_file = agent_path
			var h_headers := ["User-Agent: Challenge2026-Launcher-App", "Accept: application/octet-stream"]
			req.request(redir_url, h_headers)
			return

	is_downloading = false 
	req.download_file = ""
	if response_code != 200:
		_log("Agent download failed with HTTP code: " + str(response_code), "ERROR")
		_message("Agent download failed: " + str(response_code))
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
		OS.execute("chmod", ["-R", "+x", agent_dir + "/python/bin"])
	_on_agent_extracted.call_deferred()


func _on_agent_extracted() -> void:
	extract_thread.wait_to_finish()
	is_extracting = false 
	_seed_player_agent()
	_log("Agent bundle extraction and seeding ready.")
	_message("Agent bundle ready")
	_launch_game()


func _seed_player_agent() -> void:
	var target := agent_dir + "/scripts/agent.py"
	if FileAccess.file_exists(target):
		return
	DirAccess.make_dir_recursive_absolute(agent_dir + "/scripts")
	DirAccess.copy_absolute(agent_dir + "/agent.py", target)
	_message("Created starter agent script: " + target)


func _extract_all_from_zip(path: String, to: String) -> void:
	var reader := ZIPReader.new()
	reader.open(path)
	var files = reader.get_files()
	
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


# --- launch game ------------------------------------------------------------


func _launch_game() -> void:
	var app_path := executable_path
	if OS.has_feature("macos"):
		app_path = "%s/%s.app/Contents/MacOS/%s" % [save_dir, GAME_NAME, GAME_NAME]
		if not FileAccess.file_exists(app_path) and FileAccess.file_exists(executable_path):
			OS.execute("rm", ["-rf", save_dir + "/" + GAME_NAME + ".app"])
			OS.execute("unzip", ["-o", executable_path, "-d", base_dir])
			OS.execute("mv", [base_dir + "/" + GAME_NAME + ".app", save_dir])

	if not FileAccess.file_exists(app_path):
		_log("Game executable not found at path: " + app_path, "ERROR")
		_message("Game executable not found at: " + app_path)
		return

	if OS.has_feature("macos"):
		OS.execute("xattr", ["-rd", "com.apple.quarantine", app_path])
	if OS.has_feature("linux"):
		OS.execute("chmod", ["+x", app_path])

	var args := ["--quiet", "--", "--agent-bundle", agent_dir]
	_log("Executing game process: " + app_path)
	var pid := OS.create_process(app_path, args, true)
	_message("Game launched (pid %d). Closing launcher..." % pid)
	await get_tree().create_timer(1.5).timeout
	get_tree().quit()


func _on_exit_pressed() -> void:
	get_tree().quit()


# --- 輔助工具函式 (Helpers) ---

func _get_result_string(result: int) -> String:
	var results = {
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


func _get_file_sha256(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var ctx := HashingContext.new()
	var err = ctx.start(HashingContext.HASH_SHA256)
	if err != OK:
		_log("Failed to initialize HashingContext", "ERROR")
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	while file.get_position() < file.get_length():
		var remaining = file.get_length() - file.get_position()
		var chunk = file.get_buffer(min(remaining, 65536))
		ctx.update(chunk)
	return ctx.finish().hex_encode().to_lower()


func _read_saved_hash(hash_path: String) -> String:
	if not FileAccess.file_exists(hash_path):
		return ""
	var f := FileAccess.open(hash_path, FileAccess.READ)
	if not f:
		return ""
	var content = f.get_as_text().strip_edges()
	f.close()
	if content.is_empty():
		return ""
	return content.split(" ")[0].to_lower()


func _save_local_hash(hash_path: String, hash_val: String):
	var f := FileAccess.open(hash_path, FileAccess.WRITE)
	if f:
		f.store_string(hash_val.to_lower())
		f.close()


func _connect_req_signal(target: Callable):
	for conn in req.request_completed.get_connections():
		req.request_completed.disconnect(conn["callable"])
	req.request_completed.connect(target)

