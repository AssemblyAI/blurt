# Design

Brand assets shared by both apps, so neither app's folder depends on the other's.

| Path                         | What it is                                                        |
| ---------------------------- | ----------------------------------------------------------------- |
| `brand/AppIcon.icon`         | The app icon (Icon Composer), built for macOS and iOS             |
| `brand/blurt-ready-logo.png` | The `blurt` wordmark (720×180), tinted with the accent at runtime |

Both `App/Blurt/project.yml` and `App/BlurtiOS/project.yml` reference these paths directly.
Assets one app alone uses stay with that app (for example `App/BlurtiOS/Design/tokens.json`).
