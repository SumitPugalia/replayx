# Contributing to Replayx

Thank you for considering contributing to Replayx. This document explains how to get started and what we expect.

## Code of conduct

By participating, you agree to uphold our [Code of Conduct](CODE_OF_CONDUCT.md).

## How to contribute

- **Bug reports** — Open an [issue](https://github.com/SumitPugalia/replayx/issues) with steps to reproduce, Elixir/OTP version, and expected vs actual behavior.
- **Feature ideas** — Open an issue describing the use case; we can discuss the design before you code.
- **Pull requests** — Fixes and features are welcome. Please open an issue first for large changes.

## Development setup

```bash
git clone https://github.com/SumitPugalia/replayx.git
cd replayx
mix deps.get
mix test
```

## Before submitting

1. **Tests** — Run `mix test`. Add or update tests for new behavior.
2. **Format** — Run `mix format`.
3. **Credo** — Run `mix credo` and fix any issues.
4. **Dialyzer** — Run `mix dialyzer` (first run builds the PLT).

You can install the project’s pre-push hook to run these automatically:

```bash
mix git.install_hooks
```

Or run the script manually: `./script/pre-push` or `mix prepush`.

## Documentation

- Public functions and modules should have `@moduledoc` / `@doc` and `@spec` where appropriate.
- Generate docs locally with `mix docs` and open `doc/index.html` to verify.

## License

By contributing, you agree that your contributions will be licensed under the [Apache License, Version 2.0](LICENSE).
