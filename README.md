# Grab

A native macOS app that wraps [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and
[`ffmpeg`](https://ffmpeg.org) to download YouTube video and, optionally,
convert it to ProRes (with automatic HDR tone-mapping) for use in After
Effects.

- Pick any available format/resolution, or one click for best quality
- Optional ProRes conversion (Proxy/LT/Standard/HQ/4444), with hardware
  acceleration when available and automatic HDR → SDR tone-mapping
- Progress bar with ETA for both the download and conversion phases
- A completion notification with a "Reveal in Finder" action
- Cookie-based auth (via your browser's cookie store) for private/age-gated
  videos — Grab never asks for or handles your Google credentials directly

Grab is a personal tool, unsigned and distributed ad-hoc (no Apple Developer
ID). See [Installing](#installing) below for the one-time step macOS requires
before it'll run.

## Requirements

- macOS 14 (Sonoma) or later, Intel or Apple Silicon
- [Homebrew](https://brew.sh), with `yt-dlp` and `ffmpeg` installed:

  ```sh
  brew install yt-dlp ffmpeg
  ```

Grab looks for these in both standard Homebrew locations
(`/opt/homebrew/bin` on Apple Silicon, `/usr/local/bin` on Intel) — it
doesn't rely on your shell's `PATH`, since GUI apps don't inherit it. If
either tool isn't found, Grab tells you and gives you the exact `brew
install` command to run.

## Installing

1. Download the latest `Grab-x.y.z.dmg` from
   [Releases](../../releases).
2. Open the DMG and drag `Grab.app` into `Applications`.
3. **First launch will be blocked by Gatekeeper** — macOS doesn't recognize
   the developer because this build isn't signed with a paid Apple Developer
   ID or notarized. That's expected. To get past it, either:

   - **System Settings**: try to open Grab (it'll be blocked), then go to
     *System Settings → Privacy & Security*, scroll down, and click
     **Open Anyway** next to the mention of Grab. Confirm in the follow-up
     dialog. (On older macOS versions, right-click → Open may offer the same
     bypass directly — Apple has been tightening this over time, so which
     one you see depends on your macOS version.)
   - **Terminal** (always works, one time only): strip the quarantine flag
     macOS attaches to anything downloaded from a browser, then open it
     normally:

     ```sh
     xattr -rc /Applications/Grab.app
     ```

     (If you have a `pip`-installed `xattr` shadowing the system one, use
     `/usr/bin/xattr -rc /Applications/Grab.app` explicitly — the Python
     version doesn't support `-r`.)

You only need to do this once per install; subsequent launches are normal.

## Usage

1. Paste a YouTube URL and click **Fetch Formats**.
2. Pick a video/audio format from the table (or click **Best Quality** for
   one-click max resolution), then **Download**.
3. Optionally enable ProRes conversion and a tier in the Output section
   before downloading — Grab probes the source for HDR and tone-maps to SDR
   automatically if needed.
4. Find your file via the "Reveal in Finder" button or notification action
   when it's done.

Cookie-based auth, sleep interval, MP4 preference, and other advanced
options are under the app's Settings (⌘,).

## Building from source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a full Xcode
install (Command Line Tools alone can't build this target):

```sh
xcodegen generate
xcodebuild -project Grab.xcodeproj -scheme Grab -configuration Release \
  -destination 'platform=macOS' build
```

Or use the packaging script, which does the above and produces a DMG under
`build/`:

```sh
./scripts/release.sh
```

## License

MIT — see [LICENSE](LICENSE).
