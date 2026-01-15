# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

## Reporting a Vulnerability

Als je een security vulnerability ontdekt:

1. **Rapporteer NIET via public issues**
2. Stuur een email naar [je-email@example.com]
3. Beschrijf de vulnerability in detail
4. Geef stappen om te reproduceren als mogelijk

We streven ernaar om binnen 48 uur te reageren.

## Security Best Practices

### SSH Keys
- Gebruik sterke SSH keys (RSA 4096-bit of ED25519)
- Beveilig private keys met wachtwoorden
- Bewaak ~/.ssh/config restrictive permissions (600)

### Network Access
- Beperk SSH toegang tot trusted networks
- Gebruik firewalls om NFS/SSH traffic te beveiligen
- Overweeg VPN voor remote access

### Credentials
- Sla geen credentials op in scripts
- Gebruik environment variables of secure vaults
- Roteer SSH keys regelmatig
