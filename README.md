# MenuStats

A tiny, text-only macOS menu bar app that shows network speed, memory and disk usage.

```
↑: 2.0K   M: 5.7G
───────   ───────
↓: 980B   D: 106G
```

Click it for the full readout: per-interface speeds and totals since boot, memory as Activity Monitor
breaks it down (app, wired, compressed, cached, swap, pressure), and disk used/available/purgeable.

- No daemons or helpers, no network access, writes only one preference to disk.
- Network speeds use 64-bit interface counters, so they stay correct past 4 GiB of traffic.
- Disk "available" matches Finder (purgeable space counts as free).

## Resource usage

Measured with version 0.1.0 installed via Homebrew, on a MacBook Air (Apple M2, 8 GB) running macOS 15.6:

| | |
|---|---|
| Memory (physical footprint) | ~13 MB, peak 14 MB; no leaks after 10+ minutes (`leaks`) |
| CPU | ~0.5% of one core on average (refreshes every 2 s) |
| Download | ~72 KB prebuilt (Apple Silicon and Intel); 21 KB source on macOS 13–14 |
| Installed size | 260 KB (app 200 KB) |

## Compatibility

Tested on **Apple Silicon** (M2) with macOS 15.6. Every release is also built and smoke-tested
(`menustats --once`) by CI on Apple Silicon and **Intel** Macs running macOS 15. macOS 13, 14 and 26
should work but have **not been tested** yet. Reports are welcome in
[Issues](https://github.com/gyane14/menustats/issues).

## Install

```sh
brew install gyane14/tap/menustats
brew services start menustats   # start now and at every login
```

Needs macOS 13+. On macOS 15 and newer (Apple Silicon and Intel) Homebrew downloads a prebuilt
binary; on macOS 13–14 it builds from source, which needs Apple's Command Line Tools
(`xcode-select --install`).

Use the full name `gyane14/tap/menustats` as above. If you `brew tap gyane14/tap` first and then run
`brew install menustats`, Homebrew refuses to load it from an untrusted tap; run
`brew trust gyane14/tap` once, then install again.

Stop it with `brew services stop menustats`, or Quit from its menu.

## Uninstall

```sh
menustats-uninstall
```

This command is installed with MenuStats (since 0.1.1). It stops MenuStats and removes it
completely: the Homebrew install and its login agent, the `gyane14/tap` tap, a copy built with
`build.sh`, cached downloads and its preferences. It touches nothing else; see
[uninstall.sh](uninstall.sh). If you built MenuStats yourself, run `./uninstall.sh` from this
repository instead.

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
