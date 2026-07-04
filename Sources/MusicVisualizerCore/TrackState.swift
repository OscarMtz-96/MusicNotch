public struct TrackState: Equatable {
    public var title: String
    public var artist: String
    public var isPlaying: Bool
    public var isExpanded: Bool

    public init(
        title: String = "Midnight Drive",
        artist: String = "Prototype Mix",
        isPlaying: Bool = true,
        isExpanded: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.isExpanded = isExpanded
    }

    public mutating func togglePlayback() {
        isPlaying.toggle()
    }

    public mutating func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }
}
