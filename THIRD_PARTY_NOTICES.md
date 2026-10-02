# Third-Party Notices

Shell is MIT-licensed (see [LICENSE](LICENSE)). It builds against, links, or bundles the components below, and each one keeps its own license. Full license texts are in the upstream projects, and in `Vendor/ghostty` after `make bootstrap`.

## Linked into the app

Shell has no Swift package dependencies. Everything third-party comes in through **libghostty** (`GhosttyKit.xcframework`), which `scripts/bootstrap.sh` builds from a pinned Ghostty commit.

| Component | Used for | License |
| --- | --- | --- |
| [Ghostty / libghostty](https://github.com/ghostty-org/ghostty) | Terminal emulation, VT parsing, PTY, Metal renderer, font shaping | MIT |
| [Oniguruma](https://github.com/kkos/oniguruma) (via libghostty) | Regular expressions (link detection) | BSD-2-Clause |
| [simdutf](https://github.com/simdutf/simdutf) (via libghostty) | Fast UTF-8/UTF-16 validation and transcoding | Apache-2.0 or MIT |
| [Highway](https://github.com/google/highway) (via libghostty) | Portable SIMD | Apache-2.0 or BSD-3-Clause |
| [Wuffs](https://github.com/google/wuffs) (via libghostty) | Image decoding (Kitty graphics protocol) | Apache-2.0 or MIT |
| [glslang](https://github.com/KhronosGroup/glslang) and [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (via libghostty) | Compiling custom shaders to Metal | BSD-3-Clause / Apache-2.0 (mixed; see upstream) |
| [libpng](http://www.libpng.org/pub/png/libpng.html), [zlib](https://zlib.net) (via libghostty) | PNG and compression | libpng License, zlib License |
| [FreeType](https://freetype.org) (via libghostty) | Font rasterization helpers | FreeType License (BSD-style) |
| [Sentry Native](https://github.com/getsentry/sentry-native) (via libghostty) | libghostty's crash handler | MIT |
| Zig packages used by libghostty ([libxev](https://github.com/mitchellh/libxev), [z2d](https://github.com/vancluever/z2d), [uucode](https://github.com/jacobsandlund/uucode), [zig-objc](https://github.com/mitchellh/zig-objc)) | Event loop, 2D drawing, Unicode data, Objective-C bridge | MIT |

## Bundled resources

| Component | Where | License |
| --- | --- | --- |
| Ghostty shell integration scripts | `Shell.app/Contents/Resources/ghostty/shell-integration` | **GPLv3** (derived from [Kitty](https://github.com/kovidgoyal/kitty)'s integration). Shipped as separate script files, not linked into the app. |
| [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) (about 600 themes, via Ghostty) | `Shell.app/Contents/Resources/ghostty/themes` | MIT |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) patched with [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) symbols | `Shell.app/Contents/Resources/fonts` | SIL Open Font License 1.1 (`JetBrainsMono-OFL.txt` is bundled) / MIT (Nerd Fonts patcher) |
| Ghostty terminfo (`xterm-ghostty`) | `Shell.app/Contents/Resources/terminfo` | MIT |
| [Octicons](https://github.com/primer/octicons) `mark-github` (path data, drawn as `GitHubMark`) | `Sources/Shell/UI/DesignSystem/DesignSystem.swift` | MIT |

## Build tools (not distributed)

| Tool | License |
| --- | --- |
| [Zig](https://ziglang.org) | MIT |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT |

If you update the pinned Ghostty commit, check `Vendor/ghostty/build.zig.zon` for dependency changes and update this file.
