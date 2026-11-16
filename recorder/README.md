# recorder

The ephemeral server behind [mctrot.nyc/live](https://mctrot.nyc/live):
location tracking, posts from the road, and the radio station during a
McTrot attempt, then an archive for the website afterward.

Everything about the machine is in this folder's Nix flake. See
`CLAUDE.md` for the decisions and conventions, and the design doc linked
there for the full picture.

## Try it locally

```
cd recorder
nix run .#vm          # boots the recorder in QEMU
curl localhost:8080   # in another terminal: "hello from mctrot (local VM)"
```

The VM's console login is `root` / `recorder` (local VM only). Quit QEMU
with `Ctrl-a x`.

## The real server (step 2)

The flake describes the Droplet completely; these are the only clicks
outside it. Do them once, in this order.

**1. DigitalOcean console**

- **Droplet:** region NYC (any NYC datacenter), image Ubuntu 24.04 or
  Debian 12 (it gets replaced), 2–4 GB RAM (nixos-anywhere needs at least
  ~1.5 GB to switch kernels), IPv6 on, authentication: SSH key
  `zach@windmountainsoftware.com` (`~/.ssh/id_ed25519.pub`). Name it
  `recorder`.
- **Volume:** 20–50 GB, same datacenter, attached to the Droplet, name
  exactly `recorder-data`, "Automatically Format & Mount", ext4. The name
  is baked into `host/digitalocean.nix` as
  `/dev/disk/by-id/scsi-0DO_Volume_recorder-data`.
- **Cloud Firewall** on the Droplet: inbound TCP 80 and 443 from anywhere,
  TCP 22 from my IP only. Outbound: everything.

**2. Namecheap, Advanced DNS** (before Caddy first starts, so Let's
Encrypt can reach the names on port 80)

| Type | Host | Value |
| --- | --- | --- |
| A | `recorder` | the Droplet's IPv4 |
| AAAA | `recorder` | the Droplet's IPv6 (optional) |
| CNAME | `api` | `recorder.mctrot.nyc.` |
| CNAME | `radio` | `recorder.mctrot.nyc.` |
| CNAME | `media` | `recorder.mctrot.nyc.` |

Check with `dig +short api.mctrot.nyc` before installing.

**3. Install NixOS** (wipes the Droplet's own disk; the Volume isn't
touched because it's not in `host/disko.nix`)

```
cd recorder
nix run .#install -- <droplet-ipv4>
```

Builds on the Droplet, so no Linux builder is needed on the Mac. The box
reboots into NixOS; the old host key is gone, so drop it with
`ssh-keygen -R <droplet-ipv4>`.

**4. Demo**

```
curl https://api.mctrot.nyc          # hello from mctrot
ssh root@recorder.mctrot.nyc df -h /var/lib/mctrot   # the Volume
```

**Later changes:** `nix run .#deploy` (defaults to
`root@recorder.mctrot.nyc`; pass another `user@host` to override). A bad
deploy rolls back with `nixos-rebuild switch --rollback` on the box, or by
picking the previous generation in the GRUB menu from the Droplet console.

## The API (step 3)

`api/` is a Node 26 TypeScript service (Fastify, better-sqlite3). Node runs
the `.ts` files directly; `tsc` only type-checks. On the box it runs as
`mctrot-api.service` (user `mctrot`) behind Caddy at `api.mctrot.nyc`, with
its database at `/var/lib/mctrot/db/recorder.sqlite` on the Volume.

```
curl https://api.mctrot.nyc/health   # version = git commit, database, secrets
```

**Working on it locally**

```
cd recorder/api
nix develop ..          # Node 26, sops, ssh-to-age
npm install
npm test && npx tsc     # tests and type-check
npm run dev             # http://localhost:3000/health
```

`nix build .#api` (from `recorder/`) builds the same package the server
runs, tests included.

**After changing dependencies** (`package-lock.json`), update
`npmDepsHash` in `api/package.nix`:

```
nix run --inputs-from . nixpkgs-darwin#prefetch-npm-deps -- api/package-lock.json
```

(If you forget, the build fails with a hash mismatch showing the right
value.) npm blocks dependency install scripts by default; native packages
need `npm install-scripts approve <pkg>`, and their build in
`package.nix`.

**Logs:** `ssh root@recorder.mctrot.nyc journalctl -u mctrot-api -f`

## Secrets

Secrets live encrypted in `secrets/recorder.yaml`, readable by my SSH key
(`~/.ssh/id_ed25519`) and the Droplet's SSH host key (see `.sops.yaml`).
The box decrypts them at boot into `/run/secrets/`; services get them as
systemd credentials.

```
cd recorder
nix develop
sops secrets/recorder.yaml                                   # edit
sops decrypt --extract '["ingest-token"]' secrets/recorder.yaml   # read one
```

A new secret also needs an entry in `host/secrets.nix` and a
`LoadCredential` line on the service that uses it.

**After reinstalling the Droplet** its host key changes, so it can no
longer decrypt. Get the new key and re-encrypt:

```
ssh-keyscan -t ed25519 recorder.mctrot.nyc | cut -d' ' -f2- | ssh-to-age
# put the result in .sops.yaml as &recorder, then:
sops updatekeys secrets/recorder.yaml
```
