# Amp Visualizer

Apple Silicon macOS app (macOS 14+) for previewing audio visualizations on a square RGB LED matrix. This separate project does not modify the Senior Design firmware or Desktop zeta reference.

## Run

Open `build/Amp Visualizer.app`. Click **Capture system audio**, select your display or an audio-playing application in macOS's sharing picker, then click **Share**. Use **Demo** for a synthetic stereo signal without capture.

Choose **Waveform**, **Stereo phase**, or **Spectrum**. The display is always a square-pixel HUB75-style preview, with **32×32**, **64×64** (default), and **128×128** options. The existing amplifier firmware declares a 64×64 panel in `sdmay27-19/firmware/src/hub75.h`.

## Panel preview

The visualizer first renders to an actual N×N RGB texture. A second Metal pass enlarges those exact pixels into solid square pixels on a centered square panel that fills the available height or width. Resizing the window changes LED size, not panel resolution. Braille masking is replaced by the LED grid. Spectrum reduces its 512 analysis bins to 28, 60, or 124 panel columns using peak pooling, preserving narrow peaks that would otherwise disappear between columns.

This emulates the pixel layout and resolution, not electrical scan timing, PWM bit planes, brightness calibration, or physical panel color response. The graphical preview does not transmit panel data. The terminal controller below sends BLE commands to the separate PSL LED strip.

## Performance and analysis

Rendering has a fixed **400 FPS target**, without a rate selector or GPU benchmark. Actual completed FPS is shown at the bottom; it depends on the machine, capture, and window presentation. Visible refresh remains limited by the display. Rendering pauses when the window is minimized or fully covered.

Spectrum uses an 8192-point Hann-windowed Accelerate DFT with 5.86 Hz FFT spacing at 48 kHz and 512 logarithmic bins from 20 Hz to 20 kHz, updated at up to 120 Hz. The 170.7 ms window improves frequency detail with a slower response to transients. Waveform displays the most recent 2048 samples.

## Build

Requires Xcode / Apple Swift tools, with no third-party packages:

```sh
./build.sh
```

Source and Metal shaders are in `Sources/main.swift`. The app is locally ad-hoc signed, not notarized.

## Capture

Uses ScreenCaptureKit with Apple's content sharing picker and 48 kHz stereo system audio. No microphone, playback, file recording, network transmission, or USB commands. Minimal screen frames are discarded; audio stays in memory. Choosing an application scopes capture to that application. Protected content may not be captured.

## Verification

Release build and code signature passed. The 64×64 LED preview was visually verified in Demo mode. Live capture at 128×128 was observed at approximately 340 completed FPS with the 400 FPS target. This is an observation rather than a guaranteed sustained rate.

## HDR

The presentation layer uses RGBA16Float and extended linear Display P3 with macOS EDR enabled. Square-pixel colors are converted to linear light and scaled to the screen’s current EDR headroom, refreshed each frame. On SDR displays the multiplier is 1. HDR brightness depends on the screen and system brightness settings; screenshots do not verify physical HDR brightness. The updated Metal shaders and square-pixel view were verified in native Demo mode. API reference: [Apple EDR tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping).

## Waveform smoothing

The continuous 0–100% slider filters waveform geometry only: 0% bypasses smoothing; increasing it applies a progressively wider centered triangular filter. This softens fine waveform detail without altering audio capture, RMS readings, or spectrum analysis. The setting persists across launches and is disabled in Stereo phase and Spectrum views. Verified in the native app at 100% during live audio capture; checks passed for raw bypass, constant-signal preservation, and attenuation of alternating high-frequency samples.

## Spectrum color and beat pulse

Spectrum uses one shared horizontal gradient with three color anchors at the left, middle, and right. The palette shifts slowly as a whole, rather than cycling each frequency independently. Brightness gain stays constant. Bass onsets in the approximate 20–180 Hz band gently accelerate shared hue rotation, with a 180 ms decay and refractory period. Each onset adds only about one degree of hue rotation; steady audio keeps the slow base drift. Beat detection is a visual energy-onset heuristic, not a BPM tracker. The native gradient was visually verified; checks passed for steady-input suppression, onset response, and pulse decay.

## Stereo phase circularity

Stereo phase is enlarged 2×. The Circularity slider blends the ordinary left/right trace into an analytic-signal orbit driven by the left channel: 0% preserves raw stereo phase, while 100% uses quadrature for a rounder trace. This is a display effect and does not change audio. Large signals can extend beyond the panel at the increased zoom. The setting persists across launches and is enabled only in Stereo phase. Numerical verification passed for exact zoom, raw bypass, and constant-radius output from a test tone.

## Terminal light controller

Run the terminal version to control the same 300-light PSL BLE strip as the Xcode app:

```sh
./build-terminal.sh
./build/amp-lights
```

The main `./build.sh` also builds this executable. Allow Bluetooth access for your terminal when macOS prompts, and power on PSL. It discovers PSL by name or the Xcode service UUID, connects automatically, and sends current settings when ready. Disconnects trigger another scan.

Use left/right arrows to decrease/increase hue by 5° (wrapping around the color wheel), and up/down arrows to increase/decrease brightness by 1% (clamped to 0–100%). Press `+`/`-` to increase/decrease the segment length by one light, or `[`/`]` to move it left/right by one light. Length stays within 1–300 lights, and movement stops at the strip ends. These segment shortcuts work when the command line is empty. Changes send immediately without Enter. You can also enter commands one per line:

```text
hue 25
brightness 15
width 100
center 151
rainbow on
rainbow off
off
quit
```

`help` lists commands; `status` displays settings and connection state; `send` resends all settings. Defaults match Xcode: hue 25°, brightness 15%, all 300 lights, rainbow disabled. Hue accepts 0–360, brightness 0–100, and center/width integer values 1–300. Center is clamped so the entire segment fits. Lights outside the segment are off. Rainbow matches Xcode's 50 color runs, 30 Hz updates and ten-second cycle. `off` sets brightness to zero; restore it with `brightness`. Exiting or reaching stdin EOF leaves the lights showing their last frame.

This is a light-control terminal companion, not an audio-to-strip streaming mode. The graphical audio visualizer remains available independently. Packets use the Xcode app's service/characteristic UUIDs and version-1 `0xA0` run format. Writes honor BLE backpressure and keep the latest pending frame. If a frame exceeds the negotiated write size, the controller reports it instead of sending a partial frame; use a narrower rainbow segment or solid mode.

Offline protocol checks (no Bluetooth connection required):

```sh
./build/amp-lights --self-test
```

Build and offline checks pass; physical BLE operation requires verification with a powered PSL device.
