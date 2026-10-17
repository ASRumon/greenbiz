# App icon source

Put the new launcher icon in this folder as:

- **`app_icon.png`**
- **1024 × 1024 px**
- PNG format
- Ideally no transparency for iOS (or keep `remove_alpha_ios: true` in the config)

The path is already wired into `pubspec.yaml` under `flutter_launcher_icons`.

## After you add the PNG

From the project root:

```powershell
& 'C:\Flutter\flutter\bin\dart.bat' run flutter_launcher_icons
```

That regenerates the launcher icon on every platform:

| Platform | Output |
|---|---|
| Android | `android/app/src/main/res/mipmap-*/ic_launcher.png` |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/` |
| Web | `web/icons/` |
| Windows | `windows/runner/resources/app_icon.ico` |
| macOS | `macos/Runner/Assets.xcassets/AppIcon.appiconset/` |

Then rebuild the app.

## Android adaptive icon (optional, recommended)

A single square PNG works, but Android 8+ looks best with an adaptive icon:

1. Add **`app_icon_foreground.png`** — 1024 × 1024, transparent background, with
   the logo inside the centre ~66% safe zone.
2. Add this to the `flutter_launcher_icons` block in `pubspec.yaml`:

```yaml
  adaptive_icon_background: "#15653D"
  adaptive_icon_foreground: "assets/icon/app_icon_foreground.png"
```

3. Run `dart run flutter_launcher_icons` again.

## Notes

- Launcher icons are native resources, not Flutter bundle assets, so this folder
  is intentionally **not** listed under `flutter: assets:`.
- Keep the source PNG in version control; the generated platform files can be
  regenerated at any time.
