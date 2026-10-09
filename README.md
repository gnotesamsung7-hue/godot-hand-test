# Godot hand-tracking test

A tiny Godot 4.5 test for Night Division: does hand tracking work natively inside Godot on an Android phone?

A crosshair follows your index finger, and dropping your thumb fires at a moving target. The screen shows live diagnostics: tracking updates per second, FPS, whether a hand is seen, and the trigger value.

## How it works

- `android-plugin/` is a small native Android plugin (Kotlin). It runs MediaPipe hand tracking on the front camera and sends the 21 hand points to Godot.
- `game/` is the Godot project. `main.gd` turns the hand points into aiming and firing.
- `.github/workflows/build-apk.yml` builds the plugin, exports the APK with Godot 4.5.1, and publishes it to the `apk-latest` release.

## Install

After the Actions run turns green, open the `apk-latest` release on your phone and install `hand-test.apk`.
