# cf-nginx-realip

Automatically restores real visitor IPs in nginx access logs when your site is behind Cloudflare.

When traffic flows through Cloudflare, nginx logs Cloudflare's proxy IP instead of the visitor's real IP. This script auto-detects your nginx setup, fetches Cloudflare's published IP ranges (IPv4 + IPv6), writes a trusted-proxy include file, patches your `nginx.conf`, and sets up a weekly cron — all in one command.

## Quick Start

```bash
git clone https://github.com/angelexevior/cf-nginx-realip.git
cd cf-nginx-realip
chmod +x cfips-nginx.sh
sudo ./cfips-nginx.sh --install
```

That's it. The installer handles everything automatically.

## What `--install` does

1. **Finds your nginx binary** — checks common paths; asks if it can't find it
2. **Finds your nginx config directory** — reads it directly from nginx; asks if ambiguous
3. **Fetches Cloudflare IP ranges** — IPv4 and IPv6
4. **Writes `cfips.conf`** — atomic write with nginx config validation and auto-rollback on failure
5. **Patches `nginx.conf`** — adds `include cfips.conf;` to the `http {}` block automatically; asks you to do it manually if the structure is non-standard
6. **Reloads nginx** — via systemctl or `nginx -s reload`, whichever works
7. **Installs a weekly cron** — keeps Cloudflare IP ranges current automatically

## Options

| Flag | Description | Default |
|---|---|---|
| `--install` | Full guided installation | — |
| `-p, --path PATH` | nginx config directory (skip auto-detect) | auto |
| `-f, --file FILE` | output filename inside PATH | `cfips.conf` |
| `-H, --header HEADER` | header containing real IP | `CF-Connecting-IP` |
| `-e, --extra-cidr CIDR` | additional trusted CIDR (repeatable) | — |
| `-r, --reload` | reload nginx after IP list update | auto |
| `-n, --no-reload` | skip nginx reload | — |
| `--dry-run` | print config without writing anything | — |
| `--install-cron` | install weekly cron entry (requires `--path`) | — |
| `-h, --help` | show help | — |

## Updating the IP list manually

The cron job handles this automatically, but you can also run it on demand:

```bash
sudo ./cfips-nginx.sh --reload
```

## Verify it's working

After installation, visit your site and check the access log:

```bash
tail -f /var/log/nginx/access.log
```

The first column should show real visitor IPs, not Cloudflare ranges (`104.x`, `172.x`, `162.x`, etc.). Compare against your own public IP:

```bash
curl -s ifconfig.me
```

## Troubleshooting

**Still seeing Cloudflare IPs after install?**

```bash
# Confirm the include was loaded
sudo nginx -T 2>/dev/null | grep "set_real_ip_from" | head -5

# If empty — the include wasn't loaded. Check nginx.conf for the include line:
sudo grep -n "cfips" /etc/nginx/nginx.conf
# or
sudo grep -n "cfips" /usr/local/nginx/conf/nginx.conf
```

**Permission denied running the script?**

```bash
chmod +x cfips-nginx.sh
```

**Using a control panel (cPanel, Plesk, CyberPanel, HestiaCP)?**

Control panels often manage their own nginx config and overwrite `nginx.conf` on changes. You may need to add the include via the panel's template system instead. Run `--dry-run` to see what the config file contains, then add it through your panel's nginx template editor.

## License

MIT — see [LICENSE](LICENSE)
