# awsssh

Connect to EC2 instances over AWS SSM on macOS: a menubar port-forward manager and a shell CLI.

## Install

```sh
brew tap sratabix/taps
brew trust sratabix/taps
brew install --cask awsssh
```

That installs the Awsssh menubar app, the `awsssh` CLI, shell completions and the session-manager-plugin dependency. Needs macOS 13 or newer. The app is ad-hoc signed, so if macOS blocks it on first launch, approve it under System Settings then Privacy & Security.

## awsssh

```sh
awsssh
awsssh --instance db-01
awsssh --profile prod --region eu-central-1
```

## Menubar app

Click the menubar icon to manage background port forwards. Each forward has its own AWS profile and region, so several accounts can run at once. You can start and stop forwards, give each one a global keyboard shortcut, and turn on launch at login.

Forwards are stored in `~/Library/Application Support/Awsssh/forwards.json`, the only file awsssh writes. Your `~/.aws` files are read but never changed.

## Building

```sh
make app
make check
```

`make app` produces `dist/Awsssh.app` and a release zip. `make check` runs the same checks as CI.
