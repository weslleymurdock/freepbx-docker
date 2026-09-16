# Asterisk custom configuration

These files are templates for the GCP FreePBX image. The entrypoint copies each template to `/etc/asterisk/` only when the target file does not already exist.

The `/etc/asterisk` directory is persisted by the `freepbx_etc_data` Docker volume, so runtime edits survive container replacement.

## Important rule

Do not edit FreePBX-generated files such as `pjsip.conf`, `extensions.conf`, or other generated module configuration directly. FreePBX may regenerate them during reloads or upgrades.

Use the corresponding `*_custom.conf` or `*_custom_post.conf` include files instead.

## Main files

- `pjsip_custom.conf` — PJSIP global/auth customization, including SIP realm examples.
- `pjsip.transports_custom.conf` — PJSIP transport/NAT customization, including public GCP address examples.
- `extensions_custom.conf` — custom dialplan.
- `rtp_custom.conf` — RTP port and media options.
- `http_custom.conf` — Asterisk HTTP/WebSocket server settings.
- `manager_custom.conf` — AMI users and access control.

The templates are intentionally conservative and mostly commented out. Enable only the settings required by the deployment.
