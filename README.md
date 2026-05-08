# Zig Version Manager

A zig version manager, written in zig.

## Installation

zvm comes with prebuilt binaries for x86_64-windows and x86_64-linux.

## Features

* No static or runtime dependencies, network/verification/decompression only uses zig std.
* Automatically chooses the fatest mirror to download from.
* Cross-platform, known to work on linux and windows.
* Unfinshed, use at your own risk.

### Building

clone the repo, and run

```bash
zig build -Dreleaes
```

## Basic Usage

Install a release:
```bash
zvm install 0.16.0
```
```bash
zvm install master
```
Use a installation

```bash
zvm use 0.16.0
```
