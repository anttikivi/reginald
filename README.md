<h1 align="center">Reginald</h1>

<div align="center">

👔 the personal workstation valet

[![CI](https://github.com/anttikivi/reginald/actions/workflows/ci.yml/badge.svg)](https://github.com/anttikivi/reginald/actions/workflows/ci.yml)

</div>

Setting up a new machine and managing dotfiles should be simple. However, most
existing tools are either too heavy requiring runtimes like Python, quite
complicated forcing you into rigid workflows, or too fragile like Bash scripts
that quickly become unmaintainable.

Reginald offers a fast, reliable, and effortless workflow for this. Built in
Zig, it’s self-contained, cross-platform, and extensible through a
language-agnostic plugin system that uses JSON-RPC 2.0. You can add your own
tasks and commands with ease in any language you would like.

Reginald is the personal workstation valet: a task runner that executes tasks
idempotently according to your config file. It comes with built-in plugins for
essential tasks like linking dotfiles and installing packages. Official plugins
are provided for common developer needs. If you need more, you can extend
Reginald with any tasks you like with your own plugins.

<!-- prettier-ignore-start -->
> [!IMPORTANT]
> This project is still in early development. More info on the project will be
> added later and the current features don’t just yet match this README.
<!-- prettier-ignore-end -->

## Getting started

As Reginald is still in early development, there are no prebuilt binaries or
releases. However, feel free to build Reginald yourself and experiment with it.

### Building

Make sure you have at least [Zig](https://ziglang.org/) 0.15.2 installed. After
that, building Reginald is as simple as running the build script:

```sh
zig build
```

This produces the `reginald` executable in `./zig-out/bin`.

## License

Copyright (c) 2025 Antti Kivi

Reginald is licensed under the Apache-2.0 license. See the [LICENSE](LICENSE)
file for more information.

Please see the [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for full attribution
and license information.
