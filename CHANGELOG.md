# Changelog

## v1.0.5

- Quick connect can paste a copied forward into the form and start from there.
- What's new no longer opens itself. The version in the panel is badged until you read it.
- What's new lists every release, not just the latest one.

## v1.0.4

- What's new no longer replays every release ever written after a local build has run.

## v1.0.3

- Test a forward from the form before saving it. It opens the tunnel and connects to the target.
- Quick connect starts a forward without saving it. It runs until you stop it.
- Long names are no longer covered by a scroll bar when macOS is set to always show them.
- Automatic sign-in waits for DNS to answer, not just for a network.
- A long sign-in error wraps instead of being cut off.
- The list can no longer be dragged sideways, and a name only scrolls when it is cut off.

## v1.0.2

- The what's new window scrolls when there is more than fits, with a fade at the bottom.

## v1.0.1

- Add automatic sso sign-in, in its own window instead of a browser.
- Hide signin button when signed in.
- Dismiss all errors even when there's only one to dismiss.
- Whats new window in settings

## v1.0.0

- Dismiss all errored forwards at once.

## v0.0.9

- A bottom fade on the list marks that there is more below.

## v0.0.8

- The menubar icon fits the menu bar and stays sharp across displays.
- The attention badge is sized to the glyph.

## v0.0.7

- Update from inside the app. The download is checked against the SHA-256 GitHub publishes, and the bundle is swapped in place, so the CLI and completions keep working.
- Asks before installing when forwards are running, and says how many will stop.
- A failed update can be retried or dismissed.

## v0.0.6

- Groups, with a start and stop button per group.
- Groups collapse, and stay collapsed.
- The list scrolls once it gets long.
- Signed-in state is re-checked while the app runs, so a terminal login shows up.

## v0.0.5

- Sign in to AWS SSO from the panel: one button per SSO session.
- Colour a forward from a swatch or a hex value.
- Settings window, holding launch at login and the SSO row toggle.
- The add and edit form opens in its own window.

## v0.0.4

- Share a forward to the clipboard and import one you were sent.
- A forward that ends on its own says why.
- Long names and status lines scroll horizontally.

## v0.0.3

- Full error text per row, in a panel you can expand and dismiss.
- Releases carry a VirusTotal report link.

## v0.0.2

- Forwards reconnect after a laptop wake or a network change.
- Each running forward shows how long it has been up.
- The menubar icon is badged when a forward needs attention.

## v0.0.1

- First release.
- Menubar app for EC2 port forwards over SSM, saved between launches, each with an optional global hotkey.
- `awsssh` CLI for a shell on an instance over SSM.
- zsh, bash and fish completions.
