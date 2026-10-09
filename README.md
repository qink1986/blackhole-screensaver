# Black Hole Screensaver

A standalone Windows screensaver that renders a procedural black-hole scene in
real time. It is built as one self-contained `.scr` executable: a small Win32
host creates an OpenGL 3.3 context and renders one full-screen fragment pass.
The running screensaver does not read desktop pixels, shader files, textures,
or other external assets.

The project is designed for a cinematic, stable desktop experience rather than
as a scientific general-relativity simulator. Its current renderer uses a
Schwarzschild-style null-ray approximation, an analytic accretion disk, and a
procedural inertial sky while preserving a fixed, low-overhead runtime budget.

## Highlights

- **Single-file Windows screensaver** — standard `/s`, `/p`, and `/c` behavior
  in one `.scr`, with no installer or companion DLL.
- **OpenGL 3.3 baseline** — compatible with older integrated GPUs, including
  the Intel UHD-class hardware used for validation.
- **One full-screen rendering pass** — no FBO, post-processing chain, texture
  sampling, desktop capture, particle system, or runtime asset loading.
- **Bounded ray integration** — a fixed 48-step Schwarzschild-style path is
  used for the shadow, disk intersections, and local sky deflection.
- **Directional procedural sky** — a denser layered deep-star field, compact star
  clusters, and a faint dust band are seeded once per run. The seed selects one
  random straight world-direction drift per launch, never the black hole's
  center, roll, or size; only escaping rays in the strong-lensing region sample a deflected direction from
  that same moving sky. Deflected paths gather adjacent procedural catalogue
  cells only near a source-cell edge, without changing star size; this prevents
  a source from flashing or disappearing as it enters or exits the lens.
  Only truly near-tangential non-captured exits smoothly fall back to direct
  sky; stable escaping rays retain full deflection rather than switching at a
  binary ray-exit threshold.
- **Procedural accretion disk** — one named, fixed Schwarzschild-style scene
  holds its camera/body composition while continuous wrapped disk-space
  filaments evolve only within traced disk-plane intersections.
- **GPU back-pressure** — a 10 ms timer is a maximum submission cadence, not a
  frame-rate promise. A single OpenGL fence allows at most one frame in flight;
  busy GPUs skip work rather than queueing full ray-traced frames.
- **Safe first presentation** — the first frame is rendered and retired before
  a full-screen window becomes visible, avoiding an uninitialized black flash.

## What the renderer models

The fragment shader traces a ray from each pixel through a compact
Schwarzschild-style field. A ray can be captured by the shadow, escape to the
background sky, or enter a finite, slightly flared analytic disk body. At a
disk entry, the renderer combines these separately:

- disk density: a non-emissive inner plunging region and wrapped procedural
  disk-space filaments;
- temperature: a thin-disk-inspired radial profile;
- gravitational and Doppler terms: a stylized redshift/beaming response; and
- transmittance: opacity accumulated at disk crossings.

The resulting image is a visual approximation. It must not be used for
scientific measurement, as a Kerr solver, or as a fluid/GRMHD simulation.

## Runtime behavior

The screensaver launches directly into a near-black procedural sky. It never
captures, uploads, displays, or distorts the desktop.

The active scene is the host-owned `STATIC_SCHWARZSCHILD` composition:
center `(0.50, 0.50)`, apparent radius `0.120`, disk inclination `1.50 rad`,
and roll `0.35 rad`. Its camera/body layout and `DiskLook` remain fixed for
the whole run—there is no preset tour, Lissajous drift, or radius breathing.
Disk material and the independent directional sky may still evolve. M6
therefore has explicit relative motion: recognizable sky features translate
past the fixed black-hole composition at `SKY_FLOW_SPEED = 0.1500`; each launch
uses its `uSkySeed` to select one random fixed direction, while the sky still
does not rotate around the black-hole or screen center. In the
strong-lensing ring, a parity-reversed secondary star image can move locally
opposite that direct background flow; this is a qualitative lensing effect,
not body-following sky motion. Weak deflection remains continuously visible
out to `4.00 * B_CRIT` within the existing traced domain. `uSkySeed` controls
only sky layout and flow; no scene/material seed is active. The four sparse
procedural-star catalogue layers use twice their former occupancy, preserving
individual star size while doubling the baseline star count.

Below the truncated emissive inner edge, a non-emissive plunging-region
occluder smoothly blocks background when it enters the slim disk body. A
matching smooth ray-space inner-flow silhouette blocks background-only rays
that never enter that body. Together they keep lensed stars out of the black gap
between photon ring and visible disk without altering accumulated disk emission,
the central shadow, or the one-pass architecture.

The disk remains a bounded procedural density model evaluated once at each
outside-to-inside visit of a finite analytic slab. Its constant half-thickness
is `0.035`, giving a slight rim while preventing paired entry/exit boundaries
from double-counting material. A bounded analytic chord query tests its faces
and outer rim without subdividing the fixed 48-step geodesic loop. Continuous
wrapped filaments share a directional flow with bounded differential shear, so
long-running radii do not accumulate into an increasingly dense unresolved
sheet. They receive derivative-free footprint filtering where the critical lens
ring would otherwise leave them unresolved. There are no procedural impact
arcs, discrete clumps, particle system, fluid simulation, texture, framebuffer,
pass, or user setting.

The three `/c` settings are stored under
`HKCU\Software\BlackHoleScreensaver`:

- **Star brightness** — integer `0–100`, default `30`
- **Disk opacity** — integer `0–100`, default `90`
- **Doppler strength** — integer `0–100`, default `60`

The persisted schema records `ConfigSchemaVersion = 1`. Existing installations
without that marker remain compatible: valid legacy values are read, but the
registry is not rewritten until you explicitly choose **OK**. Missing,
malformed, wrong-type, or out-of-range values safely fall back to defaults;
an unknown future schema version falls back to all defaults rather than being
misinterpreted. Cancel and the title-bar close button never write settings.

As with a normal Windows screensaver, keyboard input, mouse buttons, or a
meaningful mouse movement exits `/s` and `/d`. Preview mode is hosted by the
screen-saver control panel.

## Requirements

- Windows 10 or Windows 11
- A GPU and driver exposing OpenGL 3.3 or later
- One of the supported build toolchains when compiling from source:
  - Visual Studio Build Tools / MSVC (preferred)
  - MinGW-w64 GCC
  - Zig (`zig cc`)
- Windows PowerShell 5.1 or later for the deterministic shader-include generator
- Git with the repository's full history only when running the historical M1–M3
  contract verifiers; the current M6 verifier does not require Git history.

## Build from source

From a Developer Command Prompt, a normal `cmd.exe`, or Explorer, run:

```bat
build.bat
```

`build.bat` performs the following in order:

1. Generates `generated\blackhole_screensaver_frag.inc` from the canonical
   `blackhole_screensaver.glsl` source.
2. Locates an available compiler.
3. Builds to a unique temporary sibling file.
4. Replaces `blackhole.scr` only after a successful compile and link.

A generator or compiler failure leaves the existing `blackhole.scr` untouched.
The script does **not** copy anything into `%SYSTEMROOT%\System32`.

To validate that the checked-in generated include matches the canonical shader
without compiling, run:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\generate-shader-include.ps1 -Check
```

## Install and run

1. Build or download `blackhole.scr`.
2. Copy it to a location recognized by the Windows screen-saver picker (for
   example, `%SYSTEMROOT%\System32`) if you want to install it system-wide.
3. Open **Settings → Personalization → Lock screen → Screen saver**.
4. Select **Black Hole**, then use **Settings** to open `/c`.

For development, the normal modes are:

```text
blackhole.scr /s        Full-screen screensaver
blackhole.scr /p <HWND> Control-panel preview host
blackhole.scr /c        Configuration dialog
blackhole.scr /d        Full-screen debug path using the normal render lifecycle
```

## Shader workflow

`blackhole_screensaver.glsl` is the only canonical fragment-shader source.
`tools\generate-shader-include.ps1` converts it deterministically into the
checked-in C string include at
`generated\blackhole_screensaver_frag.inc`. `blackhole_screensaver.c` compiles
that generated string into the `.scr`; it never loads GLSL at runtime.

Do not edit the generated include by hand. Edit the canonical GLSL, regenerate
the include, then build and validate the screensaver. The shader pipeline is
kept explicit so the Windows host, its one-frame fence policy, and the fragment
source can evolve without silently changing the shipped source of truth.

The milestone contract verifiers are development and CI tools, not runtime
requirements. The current `tools\verify-milestone-6.ps1` validates the
host-owned static scene, M4 configuration boundary, generated shader include,
M3 directional-sky isolation, and retained rendering constraints from a normal
checkout. CI then runs `tools\verify-milestone-6-runtime.ps1` against the
built `.scr`: a live `/d` process proves that the runner's OpenGL 3.3 driver
compiled and linked the embedded fragment shader. Historical M1–M3 verifiers
remain useful for their respective frozen milestones and require Git history
containing their immutable baseline commit; the M4 verifier remains as the
frozen pre-M6 configuration contract.

## Project layout

```text
blackhole_screensaver.c                  Win32/OpenGL host and screen-saver modes
blackhole_screensaver.glsl               Canonical fragment shader
generated/blackhole_screensaver_frag.inc Generated C string include (do not edit)
tools/generate-shader-include.ps1        Deterministic GLSL-to-C generator
tools/verify-milestone-*.ps1             Static and runtime acceptance checks
build.bat                                Safe local build entry point
```

## Scope and direction

This release remains a single-pass, 48-step Schwarzschild-style screensaver.
It deliberately does not ship real-time Kerr integration, an external texture
or LUT dependency, multi-pass bloom, a particle system, a live fluid solver,
or a binary-black-hole scene.

Future visual work is evaluated against the same constraints: a directional
world-sky whose motion is independent of the black-hole body, named and
physically motivated motion, separate disk density/temperature/opacity
controls, OpenGL 3.3 compatibility, and bounded GPU queue pressure.
A future spinning-lens mode, if accepted, will be clearly labeled as an
experimental approximation until it has a separately validated implementation.

## License

This repository is released under the [MIT License](LICENSE). See the license
file for the complete notice, including the source attribution applicable to
the initial accretion-disk shader adaptation.

## References

This section is an expandable record of source attribution and technical or
visual research. A listing here does **not** mean that its code, shaders,
textures, models, screenshots, generated data, or other assets are included in
this project. Any future code or asset reuse must identify the exact upstream
files and retain the required license notices.

### Existing source attribution

- [s0xDk/ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole) —
  original black-hole shader starting point for the initial disk adaptation;
  see the project [LICENSE](LICENSE) for the applicable MIT attribution.

### Research and visual references

- [Chaganti-Reddy/gargantua](https://github.com/Chaganti-Reddy/gargantua) —
  MIT-licensed research reference for directional procedural star fields
  sampled by escaped geodesics, gravitational lensing, relativistic disk
  presentation, and future spinning-lens evaluation. Its Rust/wgpu, multi-pass
  Kerr renderer is not a drop-in implementation for
  this OpenGL 3.3, single-pass screensaver.
- [denhanglim/GARGANTUA-SIMULATION](https://github.com/denhanglim/GARGANTUA-SIMULATION) —
  reference for browser-based Schwarzschild ray marching and lensed-disk visual
  studies. Its Three.js/WebGL and post-processing architecture is not imported
  here.
- [amirh0ss3in/Gargantua](https://github.com/amirh0ss3in/Gargantua) —
  visual research reference for differential disk motion and procedural
  accretion-disk visual structure. Its Taichi/Python fluid-simulation
  approach is far beyond this renderer's single-pass, fixed-step budget and is
  not included here.

The next reference may be added to this list with its purpose, upstream URL,
and verified reuse/license status.
