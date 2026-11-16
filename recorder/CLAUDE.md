# recorder/

The recorder is the ephemeral server behind mctrot.nyc/live. It runs for a
McTrot attempt, records it (location, posts, radio), produces an archive
the website keeps, and is then retired by hand. Build it to be boring,
rebuildable, and easy to throw away.

Design doc: recorder/DESIGN.md

## Decisions already made (don't relitigate)

- One NixOS machine, hostname `recorder`, on a DigitalOcean Droplet in the
  New York region with an attached Volume. Installed with nixos-anywhere,
  deployed with `nixos-rebuild switch --flake .#recorder --target-host`.
- No Docker, no Terraform, no cloud functions. Everything on the box comes
  from this folder's flake (`recorder/flake.nix`), not the repo's devenv.
- Services: Caddy (HTTPS for `api.`, `radio.`, `media.` mctrot.nyc),
  Icecast + Liquidsoap (radio), and one Node 26 LTS TypeScript API
  (Fastify, `@tus/server`, `better-sqlite3`, `@simplewebauthn`, `zod`).
  Media processing shells out to `vips` and `ffmpeg`; no `sharp`.
- SQLite on the Volume at `/var/lib/mctrot`. Backups are Volume snapshots
  plus the archive script's download. No object storage.
- Secrets via sops-nix, encrypted in `recorder/secrets/`.
- DNS lives at Namecheap: `recorder` A/AAAA record, with `api`, `radio`,
  `media` as CNAMEs to `recorder.mctrot.nyc.`.
- The public page stays `/live`: `website/live.html` plus an Elm program,
  built by `website/build.sh`. The site is no-JS by default; `/live` is an
  allowed exception, like `simulator.html`.
- The radio folder is `recorder/station/`, not `radio/`: the repo's
  `.gitignore` ignores `*radio`. Never commit the 12-hour audio file.

## How work is done

- One build step per branch and pull request, named
  `recorder/NN-short-name`. Each step adds one layer and ends with a small
  demo; write the demo in the PR description and run it before merging.
- Stay inside `recorder/` unless the step says otherwise (the `/live` page
  and replay bundles live in `website/`, the route-plan export in
  `scripts/`).
- Keep the machine reproducible: no manual changes on the box that aren't
  in the flake.

## Commands

- `nix run .#vm` (from `recorder/`): boot the local test VM. Port 80 is
  forwarded to `localhost:8080`, SSH to `localhost:2222`.
  Needs an x86_64-linux builder; on a Mac, a Linux builder such as
  nix-darwin's `linux-builder`.
- `nix run .#install -- <ip>`: first install onto a fresh Droplet
  (nixos-anywhere; wipes its disk, not the Volume).
- `nix run .#deploy`: push changes to `root@recorder.mctrot.nyc`.
  Both build on the Droplet, so no Linux builder is needed for them.
- `nix flake check`: evaluate the configuration.
- `nix fmt`: format Nix files.
