Generated test media, not user content.

silent.mp4: two seconds of generated H.264 frames, no audio.
tone-video.mp4: the same video with a generated 440 Hz stereo tone encoded as AAC.

Regenerate on macOS with:
swift generate.swift <output directory>

The Windows self-test checks native metadata, embedded audio decoding, backward and forward seeking, and sample alignment.
