# Contributing

Thanks for taking the time to improve OpenCUA. This project is a macOS-only
tool with two halves — a Swift helper that holds system permissions, and a
dependency-free Node bridge — so a useful change is usually confined to one of
them.

## Setup

```bash
git clone https://github.com/YuzuSa1t/computer-use-for-mac.git
cd opencua
./scripts/build.sh          # compiles the Swift helper and assembles the app
./scripts/install.sh        # installs to ~/.opencua and guides permissions
node server/cua.mjs doctor  # both permissions must read true
```

You need macOS 13+, Xcode Command Line Tools and Node 18+.

## Making a change

**Bridge (`server/`)**
No build step. Edit and run — `node server/cua.mjs …` always executes the
working tree. Keep it dependency-free: no `package.json`, no `node_modules`.
Anything that can be done with the Node standard library should be.

**Helper (`swift/`)**
`swift build -c release --disable-sandbox` from `swift/`, or `./scripts/build.sh`
to also reassemble and re-sign the bundle. Rebuilding changes the ad-hoc
signature, so macOS will ask for Accessibility and Screen Recording again —
expect that while developing.

**Protocol (`docs/protocol.md`)**
If you add or change an RPC method, update the reference in the same commit.
The document is the contract other clients build against.

## Before opening a pull request

- `./scripts/build.sh` completes without warnings.
- `node --check` passes on every `.mjs` file — `server/`, `server/lib/` and
  `examples/` (the same loop CI runs).
- `node server/cua.mjs doctor` reports `all_granted: true`.
- The behaviour you changed is exercised end to end — a real app, a real
  window. Unit tests cannot cover TCC, focus, or accessibility quirks, so
  describe what you actually ran in the pull request.
- Keep response payloads small. Adding a field to every response is a cost paid
  on every call; add it only when a caller needs it.

## Style

- Swift: follow the existing file layout — one engine per concern under
  `Core/`, orchestration in `Ops.swift`.
- JavaScript: ESM only, no TypeScript, no build step, 2-space indent.
- Comments explain *why*, not *what*. A comment that restates the code is
  noise; one that records a platform quirk is valuable.

## Reporting bugs

Include the app you were driving, the tool call, the response, and the output
of `node server/cua.mjs doctor`. If a click reported success but nothing
happened, say so — that is a known class of failure caused by the target app
not being frontmost, and it is worth recording which app and version.

## Security

OpenCUA requests Accessibility and Screen Recording, which is a broad grant.
Please report anything that could let an untrusted process drive the helper
without the user's knowledge — for example a way to bypass the deny-list, the
lock-screen guard, or an approval prompt — privately to the maintainers rather
than in a public issue.

## License

Contributions are accepted under the [MIT License](LICENSE).
