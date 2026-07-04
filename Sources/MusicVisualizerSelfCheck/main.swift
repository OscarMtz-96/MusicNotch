import MusicVisualizerCore

var state = TrackState()
assert(state.title == "Midnight Drive")
assert(state.isPlaying)
assert(!state.isExpanded)

state.togglePlayback()
assert(!state.isPlaying)

state.setExpanded(true)
assert(state.isExpanded)

state.setExpanded(false)
assert(!state.isExpanded)

print("MusicVisualizerSelfCheck passed")
