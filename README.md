# Leikki

A macOS screen saver: Alvar Aalto's stools, tables and Tea Trolley, and the
iittala Aalto vases, drawn as single-line hidden-line illustrations that tumble
around the screen with gentle physics. *Leikki* is Finnish for play, after
Aalto's "Ettehän unohda leikkiä" ("Don't forget to play").

## Install

Download **Leikki-Gift.zip** from the [latest release](https://github.com/ei-kyuu/leikki/releases/latest),
unzip it, and double-click **Install Leikki.command** (the read-me inside walks
through the one-time macOS approval). Or in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/ei-kyuu/leikki/main/dist/install.sh | bash
```

Then pick **Leikki** in System Settings → Screen Saver, and use **Options…** to
choose the objects (stools / tables + tea trolley / vases) and the text layout.

The installer also sets up a small daily updater (`com.aq.leikki.updater`) that
installs new releases automatically. **Uninstall Leikki.command** (or
`dist/uninstall.sh`) removes everything.

Needs macOS 13 or later; universal (Apple silicon and Intel).

## How it's drawn

Each piece is a small 3D model in centimetres (`src/STStoolModel.m`), built
from the manufacturers' published dimension drawings: Artek's plan and
elevation drawings for the furniture, and a dimensioned plan of the Aalto vase
for the glass. It is rendered as an orthographic hidden-line drawing (creases
and silhouettes, tested against a depth buffer), and glass also shows the lines
behind its front faces, faintly. `src/STStoolView.m` runs 2D rigid-body physics
on the drawings' convex hulls.

## Building and releasing

```bash
./build.sh                 # build and install a local copy
./preview.sh               # windowed preview
./release.sh 1.1 "notes"   # build the shared copy and publish a GitHub release
```

The shared build uses Helvetica Neue (built into macOS). Akkurat is a licensed
Lineto font and is never committed or published; a local `src/fonts/Akkurat.ttf`
is only bundled into `./build.sh` copies.

An unofficial tribute; not affiliated with Artek or iittala.
