# Homey SHS Toolkit

A collection of tools and scripts for Homey Self-Hosted Server users who want more control over their installation.

## Why this toolkit?

The standard Homey SHS installation works fine for most users, but offers little flexibility. Updates are automatically installed on every restart, storage and network settings are chosen for you, and there's no built-in backup strategy.

As a tech enthusiast, I want to decide:
- **When** updates are applied (not automatically on every reboot)
- **Where** my container runs (my own storage and network choices)
- **How** I can roll back if an update causes problems

These tools started as personal scripts for my own setup. I figured others might have similar needs, so I'm happy to share them here.

## Contents

| Tool | Description |
|------|-------------|
| [Proxmox Interactive Installer](Proxmox_Interactive_Installer/) | Installation wizard with choices for storage, network, VLAN, and auto-update |
| [Manual Update Control](Homey_SHS_Manual_update/) | Scripts to disable automatic updates and manually update with backup/rollback |

## Disclaimer

These tools are unofficial and not supported by Athom. Use at your own risk and always create a backup first.
