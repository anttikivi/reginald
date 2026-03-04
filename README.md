# Reginald

Reginald is a deterministic workstation bootstrap and maintenance tool.

It prepares a workstation personal development environment exactly as described
in a configuration file by orchestrating small, independent plugins. Reginald
itself is not responsible for installing packages, managing runtimes, or
performing other system operations. Instead, it plans and executes tasks
provided by plugins in a deterministic order.

The goal is simple: describe the desired state of a machine and have Reginald
bring the system to that state without guesswork, hidden behavior, or long‑term
internal state.

It is still in very early development and the design is still evolving.

## License

© 2026 Antti Kivi

Reginald is licensed under GNU General Public License v3.0. Please see
[LICENSE](LICENSE) for more information.

The documentation of Reginald is licensed under Creative Commons Attribution 4.0
International. Please see [LICENSES/CC-BY-4.0.txt](LICENSES/CC-BY-4.0.txt) for
more information.
