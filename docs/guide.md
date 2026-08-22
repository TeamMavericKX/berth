# berth guide (humans)

Five minutes, start to leaving-clean. Commands assume `berth` is on your PATH; substitute `./zig-out/bin/berth` if you built from source.

## Install

```
git clone https://github.com/TeamMavericKX/berth && cd berth
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/berth /usr/local/bin/   # optional; the proxy itself never needs sudo
```

No runtime, no package manager, no node_modules.

## Run something

```
berth run -- npm run dev
# berth: myapi.localhost -> 127.0.0.1:4312 (pid 51234)
```

That URL is live now. The app got a free port from 4000–4999 via `PORT`, plus real flags appended when the framework ignores `PORT` (vite, astro, ng, expo, …). Ctrl-C stops the app and removes the route and hosts entry.

Name it explicitly or let berth infer from `package.json`:

```
berth run --name api -- node server.js     # api.localhost
cd ~/repo                                  # worktree? branch feature/auth becomes auth-<name>.localhost
```

## HTTPS

Browsers only believe certificates they can verify:

```
berth trust        # mints + installs a local CA; prints the cert path
```

One prompt may appear (macOS keychain). After this every route answers on `https://<name>.localhost:<port>` too — plain HTTP requests redirect there automatically. Undo later with `berth clean`.

## The dashboard

Open the port shown when serving (default **8080**):

```
berth serve --port 8080
```

You get every registered app, live-scanned listeners with guessed names, Docker/Podman containers tagged `origin=container`, kill buttons, and label editing. Agents: see [agents.md](agents.md) for the markdown contract.

## Stop a runaway process

Dashboard button, or:

```
curl -X POST 'http://localhost:8080/api/kill?port=4312'
```

SIGTERM first, SIGKILL after two seconds if needed. It reports which one happened.

## Keep it running across reboots

```
berth service install      # user-level unit; no sudo
berth service status       # manager=systemd running=yes startup=enabled
berth service uninstall    # reverses cleanly
```

macOS uses a LaunchAgent (`~/Library/LaunchAgents/dev.berth.proxy.plist`); Linux uses a systemd user unit. Homebrew-managed binaries are told to use `brew services` instead.

## Share over tailscale

```
berth run --tailscale -- npm run dev    # your tailnet only
berth run --funnel -- npm run dev       # public internet via funnel
```

Prints the ts.net URL and attaches it to the route (dashboard shows it). Tailscale missing or asleep? You get one clear line and the app still runs locally.

## Leave with zero residue

```
berth clean          # asks before each step
berth clean --yes    # for scripts; refuses in non-interactive shells without it
```

Removes state dir, trust entry, and the /etc/hosts block. Machine returns to exactly what it was.
