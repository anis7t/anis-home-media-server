# Seek preview

The player seek bar provides three independent hover/interaction layers:

- played position (red)
- live media `TimeRanges` buffered ranges (white)
- hover target preview with an exact timestamp and cached video frame

Hovering never changes `video.currentTime`; only primary pointer interaction seeks.

Preview frames are generated on demand and cached under the normal media-server cache directory. Sampling is 5 seconds for videos under 30 minutes, 10 seconds under 2 hours, and 15 seconds for longer videos.
