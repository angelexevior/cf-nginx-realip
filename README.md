# cf-nginx-realip

Automatically restores real visitor IPs in nginx access logs when your site is behind Cloudflare.

When traffic flows through Cloudflare, nginx logs Cloudflare's proxy IP instead of the visitor's real IP. This script fetches Cloudflare's published IP ranges and writes an nginx include file that tells nginx to trust those ranges and read the real IP from the `CF-Connecting-IP` header.

## Quick Start

```bash
# 1. Clone and make executable
git clone https://github.com/angelexevior/cf-nginx-realip.git
cd cf-nginx-realip
chmod +x cfips-nginx.sh

# 2. Run once to generate the include file
#    (defaults to /etc/nginx — adjust with --path if different)
sudo ./cfips-nginx.sh

# 3. Add to your nginx.conf (inside the http block)
#    include cfips.conf;

# 4. Reload nginx
sudo systemctl reload nginx
```

## Options

| Flag | Description | Default |
|---|---|---|
| `-p, --path PATH` | nginx config directory | `/etc/nginx` |
| `-f, --file FILE` | output filename inside PATH | `cfips.conf` |
| `-H, --header HEADER` | header containing real IP | `CF-Connecting-IP` |
| `-e, --extra-cidr CIDR` | additional trusted CIDR (repeatable) | — |
| `-r, --reload` | reload nginx after update | auto-detect |
| `-n, --no-reload` | skip nginx reload | — |
| `--dry-run` | print config without writing | — |
| `--install-cron` | install weekly cron entry | — |
| `-h, --help` | show help | — |

## Examples

```bash
# Custom nginx path (e.g. compiled from source)
sudo ./cfips-nginx.sh --path /usr/local/nginx/conf

# Also trust an internal load balancer
sudo ./cfips-nginx.sh --extra-cidr 10.0.0.0/8

# Preview what would be written without changing anything
./cfips-nginx.sh --dry-run

# Install as a weekly cron job
sudo ./cfips-nginx.sh --install-cron

# Use X-Forwarded-For instead of CF-Connecting-IP
sudo ./cfips-nginx.sh --header X-Forwarded-For
```

## Keeping IPs Current

Cloudflare occasionally updates their IP ranges. Install a cron job to auto-update:

```bash
sudo ./cfips-nginx.sh --install-cron
```

This creates `/etc/cron.d/cf-nginx-realip` with a weekly entry. The script is idempotent — it skips the nginx reload if the IP list hasn't changed.

## nginx.conf Integration

Add this inside your `http` block:

```nginx
http {
    include cfips.conf;
    ...
}
```

The generated file contains entries like:

```nginx
# Cloudflare IPv4
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
...

# Cloudflare IPv6
set_real_ip_from 2400:cb00::/32;
...

real_ip_header CF-Connecting-IP;
real_ip_recursive on;
```

## Common nginx Config Paths

| Distribution / Setup | Path |
|---|---|
| Ubuntu/Debian (apt) | `/etc/nginx` |
| CentOS/RHEL (yum) | `/etc/nginx` |
| Compiled from source | `/usr/local/nginx/conf` |
| OpenResty | `/usr/local/openresty/nginx/conf` |
| Docker (official image) | `/etc/nginx` |

## License

MIT — see [LICENSE](LICENSE)
