extends Node
## GameState — session-scoped state that outlives a scene change.
##
## M1 keeps this deliberately thin: identity for the local crew member and the
## reason we bounced back to the menu. Oxygen, salvage and run score land in M2/M3.

const DEFAULT_COLORS: Array[Color] = [
	Color(0.36, 0.78, 1.0),   # ice
	Color(1.0, 0.55, 0.18),   # ember
	Color(0.45, 1.0, 0.58),   # bio
	Color(0.95, 0.35, 0.45),  # signal
	Color(0.78, 0.55, 1.0),   # void
	Color(1.0, 0.88, 0.35),   # sodium
]

## Set before host()/join(); sent to the host on connect.
var local_name: String = "SALVAGER"
var local_color: Color = DEFAULT_COLORS[0]

## Populated when we leave a session, consumed and cleared by the main menu.
var last_status_message: String = ""


func sanitize_name(raw: String) -> String:
	var trimmed: String = raw.strip_edges()
	if trimmed.is_empty():
		trimmed = "SALVAGER"
	return trimmed.substr(0, 14).to_upper()


func report(message: String) -> void:
	last_status_message = message


func consume_status() -> String:
	var message: String = last_status_message
	last_status_message = ""
	return message
