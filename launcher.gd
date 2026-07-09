extends Control

const GITHUB_API := "https://api.github.com/repos/CSIE-Challenge/Challenge2026/releases/latest"
const SAVE_DIR := "GameBuilds"
const AGENT_PATH := "GameBuilds/agent.zip"
const AGENT_DIR := "GameBuilds/agent"
const GAME_NAME := "Challenge2026"

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
var game_downloaded := false

@onready var loading_screen := $LoadingScreen
@onready var status_label := $LoadingScreen/Label
@onready var video_player := $LoadingScreen/VideoStreamPlayer
@onready var req := $HTTPRequest


func _message(message: String):
	status_label.text = message
	print(message)


func _ready():
	video_player.size = get_viewport_rect().size
	video_player.finished.connect(_play_random_video)
	_play_random_video()
	loading_screen.visible = true
	var dir := DirAccess.open(".")
	if not dir.dir_exists(SAVE_DIR):
		dir.make_dir_recursive(SAVE_DIR)
		_message("Created save directory: " + SAVE_DIR)

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


## Release asset name for this platform's agent bundle, e.g. agent-linux-x86_64.zip.
## Matches the PLATFORM_LABEL produced by Challenge2026/agent/build_agent_bundle.sh.
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
		arch = "x86_64"
	else:
		return ""

	return "agent-%s-%s.zip" % [os_label, arch]


func _get_existing_executable_name() -> String:
	var dir := DirAccess.open(SAVE_DIR)
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
	var full_path = SAVE_DIR + "/" + file_name
	if FileAccess.file_exists(full_path):
		DirAccess.remove_absolute(full_path)
		_message("Deleted old version: " + file_name)


func _fetch_latest_release():
	_message("Checking for updates...")
	req.request_completed.connect(_on_fetch_completed)
	req.request(GITHUB_API)


func _on_fetch_completed(_result, response_code, _headers, body):
	if response_code != 200:
		_message("Failed to fetch release data: " + str(response_code))
		return

	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("assets") or not data.has("tag_name"):
		_message("Invalid release data")
		return

	var tag = data["tag_name"]
	version = tag
	executable_name = "%s_%s_%s" % [version, GAME_NAME, _get_platform_suffix()]
	executable_path = "%s/%s" % [SAVE_DIR, executable_name]

	var agent_asset_name := _get_agent_asset_name()
	for asset in data["assets"]:
		var asset_name = asset["name"]
		if asset_name == agent_asset_name:
			agent_url = asset["browser_download_url"]
		elif asset_name == executable_name:
			asset_url = asset["browser_download_url"]

	if asset_url == "":
		_message("No matching asset found: " + executable_name)
		return

	if agent_url == "":
		_message("No agent bundle found in release assets.")
		return

	var existing = _get_existing_executable_name()
	if existing == executable_name:
		_message("You already have the latest version: " + version)
		_ensure_agent_bundle()
	else:
		if existing != "":
			_delete_existing_executable(existing)
		_download_executable()


func _download_executable():
	_message("Downloading latest version: " + executable_name)
	req.download_file = executable_path
	req.request_completed.disconnect(_on_fetch_completed)
	req.request_completed.connect(_on_download_completed)
	req.request(asset_url)


func _on_download_completed(_result, response_code, _headers, _body):
	if response_code != 200:
		_message("Download failed: " + str(response_code))
		return

	if OS.has_feature("macos"):
		OS.execute("unzip", [executable_path])
		OS.execute("mv", [GAME_NAME + ".app", SAVE_DIR])

	game_downloaded = true
	_message("Download complete")
	_ensure_agent_bundle()


# --- agent bundle -----------------------------------------------------------


## Make sure the Python agent bundle is extracted, then start the session.
## Re-downloads when the game was just updated or the bundle is missing.
func _ensure_agent_bundle():
	var have_bundle := FileAccess.file_exists(AGENT_DIR + "/runner.py")
	if have_bundle and not game_downloaded:
		_seed_player_agent()
		_launch_game()
		return
	_download_agent()


func _download_agent():
	_message("Downloading agent bundle...")
	req.download_file = AGENT_PATH
	if req.request_completed.is_connected(_on_fetch_completed):
		req.request_completed.disconnect(_on_fetch_completed)
	if req.request_completed.is_connected(_on_download_completed):
		req.request_completed.disconnect(_on_download_completed)
	req.request_completed.connect(_on_agent_downloaded)
	req.request(agent_url)


func _on_agent_downloaded(_result, response_code, _headers, _body):
	if response_code != 200:
		_message("Agent download failed: " + str(response_code))
		return

	_message("Extracting agent bundle...")
	DirAccess.make_dir_recursive_absolute(AGENT_DIR)
	_extract_all_from_zip(AGENT_PATH, AGENT_DIR)
	DirAccess.remove_absolute(AGENT_PATH)
	if not OS.has_feature("windows"):
		OS.execute("chmod", ["-R", "+x", AGENT_DIR + "/python/bin"])
	_seed_player_agent()
	_message("Agent bundle ready")
	_launch_game()


## Seed the player's editable agent script where the game's file dialog opens
## (<executable dir>/agent/scripts). scripts/ is not part of the bundle zip,
## so updates never overwrite the player's edits.
func _seed_player_agent() -> void:
	var target := AGENT_DIR + "/scripts/agent.py"
	if FileAccess.file_exists(target):
		return
	DirAccess.make_dir_recursive_absolute(AGENT_DIR + "/scripts")
	DirAccess.copy_absolute(AGENT_DIR + "/agent.py", target)
	_message("Created starter agent script: " + target)


func _extract_all_from_zip(path: String, to: String) -> void:
	var reader := ZIPReader.new()
	reader.open(path)
	var root := DirAccess.open(to)
	for file_path in reader.get_files():
		if file_path.ends_with("/"):
			root.make_dir_recursive(file_path)
			continue
		root.make_dir_recursive(root.get_current_dir().path_join(file_path).get_base_dir())
		var f := FileAccess.open(root.get_current_dir().path_join(file_path), FileAccess.WRITE)
		f.store_buffer(reader.read_file(file_path))
		f.close()


# --- launch game ------------------------------------------------------------


func _launch_game() -> void:
	if not FileAccess.file_exists(executable_path):
		_message("Game executable not found at: " + executable_path)
		return

	var app_path := executable_path
	if OS.has_feature("macos"):
		app_path = "%s/%s.app/Contents/MacOS/%s" % [SAVE_DIR, GAME_NAME, GAME_NAME]
		OS.execute("xattr", ["-rd", "com.apple.quarantine", app_path])
	if OS.has_feature("linux"):
		OS.execute("chmod", ["+x", app_path])

	# Engine args first; everything after `--` reaches OS.get_cmdline_user_args().
	var bundle_abs := DirAccess.open(".").get_current_dir().path_join(AGENT_DIR)
	var args := ["--quiet", "--", "--agent-bundle", bundle_abs]
	var pid := OS.create_process(app_path, args, true)
	_message("Game launched (pid %d). Closing launcher..." % pid)
	await get_tree().create_timer(1.5).timeout
	get_tree().quit()


func _on_exit_pressed() -> void:
	get_tree().quit()
