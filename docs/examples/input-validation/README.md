# Input validation example (launcher UI)

A reference example for doing good input validation on network-style fields in
the launcher UI (`libvirt-ui`).

> **Why it lives here and not in `libvirt-ui/`:** in this repository `libvirt-ui`
> is a git *submodule* (a pointer to a separate repo that isn't checked out
> here), so files can't be committed into it from this repo. These files are
> kept here as a tracked, copy-paste-ready reference. Drop them into the real
> `libvirt-ui` app at the paths below.

## Files & where they go

| This example | Copy into `libvirt-ui` |
|--------------|------------------------|
| `lib/validation.ts` | `src/app/lib/validation.ts` |
| `screens/network-settings-dialog.tsx` | `src/app/screens/network-settings-dialog.tsx` |

The folder structure here mirrors the target, so the relative import in the
dialog (`../lib/validation`) already resolves correctly once copied.

## What it demonstrates

**`lib/validation.ts`** — pure, framework-agnostic validators with no UI
dependency (reusable in components, IPC handlers, config parsing, and tests):

- `validateIpv4` — e.g. `10.0.1.11`
- `validateIpv4Cidr` — e.g. `10.0.0.0/24`
- `validateDomain` — e.g. `api.lab.forge.local`
- `validateHostPort` — e.g. `api.lab.forge.local:5901`

Each validator returns `{ ok: true }` or `{ ok: false, message }`, where the
message is **specific and includes a correct example** — so the error itself
teaches the right answer (e.g. _"An IPv4 address has 4 parts separated by dots —
this has 5. Example: 10.0.1.11"_).

**`screens/network-settings-dialog.tsx`** — an example dialog showing the UX
pattern:

1. Show a **format hint** before the user types.
2. Don't nag — only show an error once a field is **touched** (blurred) or the
   form is submitted.
3. On error, show the **specific, example-bearing** message.
4. Show a subtle **"Looks good"** affordance when valid.
5. Keep **Save disabled** until every field is valid; a blocked submit reveals
   all outstanding errors at once.

## Adapting to your standard Input component

The dialog uses a small local `ValidatedField` built on a plain `<input>` so the
example is self-contained. To use your app's standard Input component, replace
the marked `<input>` (search for `SWAP HERE` in the dialog) — keep the same
wiring: `value`, `onChange`, `onBlur`, `aria-invalid`, and `aria-describedby`.

The inline styles are only there to make the example render standalone; in the
real app, prefer your existing stylesheet / component library.
