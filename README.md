# ZNVR

A remote control for [neovim](https://neovim.io/).

## Features

- Manually select or automatically detect neovim socket address
- Support for --remote, --remote-tab, --remote-send, --remote-expr from vim/neovim
- Supports Windows, macOS, and Linux

## Why ZNVR Instead of Neovim CLI

Neovim CLI has some behaviors that are inflexible and high friction. Neovim CLI will not auto
detect a socket address. Neovim CLI will fail out of a lot of scenarios by opening a new
interactive neovim instance.

Neovim developers don't seem committed to building quality of life features around the current
remote interface (as is their prerogative). https://github.com/neovim/neovim/pull/18414

## Why ZNVR Instead of neovim-remote

Znvr builds a single mostly static binary with no runtime needed. Znvr treats windows as a
first-class target.

## Why Zig?

It's got a lot of buzz and I wanted to give it a try. It's got great C interop and is good
for building a small, self-contained executable.

## Building from Source

`zig build-exe src/znvr.zig`
