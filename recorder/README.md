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
