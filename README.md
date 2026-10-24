# MenuStats

A tiny, text-only macOS menu bar app that shows network speed, memory and disk usage.

```
↑: 2.0K   M: 5.7G
───────   ───────
↓: 980B   D: 106G
```

Click it for the full readout: per-interface speeds and totals since boot, memory as Activity Monitor
breaks it down (app, wired, compressed, cached, swap, pressure), and disk used/available/purgeable.

- ~13 MB of memory, ~0% CPU, no daemons or helpers, no network access, writes only one preference to disk.
- Network speeds use 64-bit interface counters, so they stay correct past 4 GiB of traffic.
- Disk "available" matches Finder (purgeable space counts as free).

## Install

```sh
brew install gyane14/tap/menustats
brew services start menustats   # start now and at every login
```

Needs macOS 13+ and Apple's Command Line Tools (`xcode-select --install`); Homebrew builds it from source.

Stop it with `brew services stop menustats`, or Quit from its menu.

## Build manually

```sh
./build.sh   # builds ~/Applications/MenuStats.app
```

A manually built copy registers itself as a login item on first launch; toggle it from its menu.

`MenuStats --once` prints one reading to the terminal.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests need a one-time [CLA](CLA.md) signature.

## License

GPL-3.0. See [LICENSE](LICENSE).
