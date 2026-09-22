# Contributing to Vitals

Thanks for helping improve Vitals.

Vitals is a native macOS system monitor built with Swift, AppKit and C++17. Contributions are welcome in the form of bug reports, reproducible test cases, documentation improvements, performance work and pull requests.

## Before opening an issue

Please check whether the problem has already been reported. When reporting a bug, include:

- macOS version
- Mac model and Apple silicon generation
- Vitals version
- exact steps to reproduce
- expected and actual behavior
- whether the privileged helper is enabled
- screenshots or logs when useful

Avoid posting private information such as usernames, file paths containing personal data, network credentials or serial numbers.

## Building

Requirements:

- macOS 13+
- Xcode 15+
- Swift 5.9+

```bash
git clone https://github.com/slawek19926/Vitals.git
cd Vitals
./build.sh
open build/Vitals.app
```

`open Package.swift` opens the project in Xcode.

## Project layout

- `Sources/App` — Swift + AppKit application
- `Sources/SysCore` — C++17 low-level monitoring layer
- `Sources/Helper` — privileged XPC helper
- `Sources/HelperKit` — shared helper protocol
- `Resources` — application resources and build metadata

## Pull requests

Keep changes focused and explain why they are needed. For UI changes, attach before/after screenshots when possible. For monitoring changes, mention the tested Mac model and macOS version.

Please do not bundle unrelated refactors into a bug fix.

## License

By contributing, you agree that your contribution will be distributed under the GNU GPL v3 license used by this repository.
