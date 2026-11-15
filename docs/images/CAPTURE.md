# Screenshot provenance

ChipBar 4.0.0 screenshots were captured from the running native SwiftUI app on a macOS Apple Silicon GitHub Actions runner. They are not AI-generated images.

Telemetry: live Apple Silicon telemetry from GitHub-hosted M-series Mac

Capture command: `ChipBar --snapshot <output> [--settings|--cluster]`.
When hardware sensors are unavailable on CI, a recorded real M1 Pro macmon sample is explicitly injected; this is a UI demonstration, not a live reading.
Operating system: macOS-15.8.2-arm64-arm-64bit-Mach-O

## User-supplied real-device gallery (originals committed)

The five originals supplied on 2026-11-16 are distinct from prior CI-generated captures. Preserve original bytes. Match filename and pixels exactly:

| File | Native pixels | Original SHA-256 |
| --- | --- | --- |
| user-dashboard.png | 848×1972 | 1889ddc7680496f616f19bffee7e2c58918608ce0f1c66d052c29f39fef072dc |
| user-power.png | 932×1372 | a7e47cd397231a7f6e297be1088e1d1ce5c877667dbb25113a1918d12207e8ab |
| user-cluster.png | 848×794 | bf14f385b7544f863bef16e483423ca91e102bb19e464d49d76c6a5d072ccc8c |
| user-ssd.png | 720×912 | 421c61e0ea65ecdbd57baceee36f2aa0c3af52bf4ead970a252b4ac6eaa085d1 |
| user-settings.png | 848×1304 | a41e3adbc925d043d1cf55bbb890824156059fc79ca6bfb03bef8803888360bd |

All five images are committed at `docs/images/user-*.png`. Their exact Git blob SHA-1 and SHA-256 were checked against the developer-provided original PNG bytes prior to merging. The README links to these images and only scales their display width; original resolution and pixels are unchanged.
