extends VideoStreamPlayer

var videos: Array[VideoStream] = [
	preload("res://Videos/yuanshou.ogv"),
	preload("res://Videos/catlaugh.ogv"),
	preload("res://Videos/catbonk.ogv"),
	preload("res://Videos/chipichapa.ogv"),
	preload("res://Videos/cathuh.ogv"),
	preload("res://Videos/catdance.ogv"),
	preload("res://Videos/catscream.ogv")
]
var last_index = -1

func _ready() -> void:
	size = get_viewport_rect().size
	finished.connect(_play_random_video)
	_play_random_video()
	visible = true


func _play_random_video():
	if videos.is_empty():
		return
	var index := randi() % videos.size()
	if videos.size() > 1:
		while index == last_index:
			index = randi() % videos.size()
	last_index = index
	stream = videos[index]
	play()
