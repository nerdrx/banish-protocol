class_name Deck
extends Node3D
## Root of a playable deck. Owns the replication rig (spawner + player
## container) and hands out crew drop points.
##
## Every peer loads this scene locally; only spawned player nodes are
## replicated across the wire.

@onready var _spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _builder: LayerBuilder = $LayerBuilder


func _ready() -> void:
	Net.world_ready(self, _spawner)


func get_spawn_point(index: int) -> Transform3D:
	return _builder.get_spawn_point(index)
