extends Control

const GITHUB_API := "https://api.github.com/repos/CSIE-Challenge/Challenge2026/releases/latest"
const GAME_NAME := "Challenge2026"

var base_dir: String
var save_dir: String
# The agent lives beside GameBuilds/, not inside it: GameBuilds/ is disposable
# (wiped/replaced on updates) while agent/ holds the player's own scripts.
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
var game_downloaded := false
var extract_thread: Thread

@onready var loading_screen := $LoadingScreen
@onready var status_label := $LoadingScreen/Label
@onready var video_player := $LoadingScreen/VideoStreamPlayer
@onready var req := $HTTPRequest


func _message(message: String):
	status_label.text = message
	print(message)


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
	video_player.size = get_viewport_rect().size
	video_player.finished.connect(_play_random_video)
	_play_random_video()
	loading_screen.visible = true

	base_dir = _get_base_dir()
	if base_dir == "":
		return

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
	executable_path = "%s/%s" % [save_dir, executable_name]

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
		OS.execute("rm", ["-rf", save_dir + "/" + GAME_NAME + ".app"])
		OS.execute("unzip", ["-o", executable_path, "-d", base_dir])
		OS.execute("mv", [base_dir + "/" + GAME_NAME + ".app", save_dir])

	game_downloaded = true
	_message("Download complete")
	_ensure_agent_bundle()


# --- agent bundle -----------------------------------------------------------


## Make sure the Python agent bundle is extracted, then start the session.
## Re-downloads when the game was just updated or the bundle is missing.
func _ensure_agent_bundle():
	var have_bundle := FileAccess.file_exists(agent_dir + "/runner.py")
	if have_bundle and not game_downloaded:
		_seed_player_agent()
		_launch_game()
		return
	_download_agent()


func _download_agent():
	_message("Downloading agent bundle...")
	req.download_file = agent_path
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
	# Extract on a worker thread so the loading video keeps playing.
	extract_thread = Thread.new()
	extract_thread.start(_extract_agent_bundle)


## Runs on the worker thread; filesystem work only, no scene tree access.
func _extract_agent_bundle() -> void:
	DirAccess.make_dir_recursive_absolute(agent_dir)
	_extract_all_from_zip(agent_path, agent_dir)
	DirAccess.remove_absolute(agent_path)
	if not OS.has_feature("windows"):
		OS.execute("chmod", ["-R", "+x", agent_dir + "/python/bin"])
	_on_agent_extracted.call_deferred()


func _on_agent_extracted() -> void:
	extract_thread.wait_to_finish()
	_seed_player_agent()
	_message("Agent bundle ready")
	_launch_game()


## Seed the player's editable agent script where the game's file dialog opens
## (<launcher dir>/agent/scripts). scripts/ is not part of the bundle zip,
## so updates never overwrite the player's edits.
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
	var app_path := executable_path
	if OS.has_feature("macos"):
		app_path = "%s/%s.app/Contents/MacOS/%s" % [save_dir, GAME_NAME, GAME_NAME]
		if not FileAccess.file_exists(app_path) and FileAccess.file_exists(executable_path):
			OS.execute("rm", ["-rf", save_dir + "/" + GAME_NAME + ".app"])
			OS.execute("unzip", ["-o", executable_path, "-d", base_dir])
			OS.execute("mv", [base_dir + "/" + GAME_NAME + ".app", save_dir])

	if not FileAccess.file_exists(app_path):
		_message("Game executable not found at: " + app_path)
		return

	if OS.has_feature("macos"):
		OS.execute("xattr", ["-rd", "com.apple.quarantine", app_path])
	if OS.has_feature("linux"):
		OS.execute("chmod", ["+x", app_path])

	# Engine args first; everything after `--` reaches OS.get_cmdline_user_args().
	var args := ["--quiet", "--", "--agent-bundle", agent_dir]
	var pid := OS.create_process(app_path, args, true)
	_message("Game launched (pid %d). Closing launcher..." % pid)
	await get_tree().create_timer(1.5).timeout
	get_tree().quit()


func _on_exit_pressed() -> void:
	get_tree().quit()
