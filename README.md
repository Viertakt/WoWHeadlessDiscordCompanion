# WHDC Addon (WoW 1.12.1 / Turtle WoW)

This repository contains a **Lua-only WoW addon** for vanilla 1.12.1 clients (including Turtle WoW API extensions).

## Files

- `WoWHeadlessDiscordCompanion.toc`
- `WoWHeadlessDiscordCompanion.lua`

The `.toc` and `.lua` names match (`WoWHeadlessDiscordCompanion`).

## IPC model

It uses WoW's in-game addon message channel (`SendAddonMessage`/`CHAT_MSG_ADDON`) and supports bridge sync-channel chat transport (`CHAT_MSG_CHANNEL`) for `CHANNEL` forwarding with queued/rate-limited sends.

Signature algorithm used by the addon:

`sig = sum(bytes((cmd|nonce|payload) + "|" + password)) mod 65535`

Line format (Envelope A):

`cmd|nonce|payload|sig`

It also accepts file-transport compatibility frames (Envelope B):

`ts|cmd|nonce|payload|sig`

## What it does

- Registers `/whdc` as the main slash command.
- Supports `/whdc pwd <password> [channel]` for password + IPC channel setup.
- Stores payloads in addon SavedVariables and attempts SuperWoW/Turtle-style export to `/wow/imports/<name>.txt` when a file API is available.
- Sends and validates signed IPC lines over the WoW addon channel.
- Rejects malformed/unsigned/replayed frames.
- Handles baseline protocol commands like `PING`/`PONG` and `CHANNEL`/`CHANNEL_ACK`.
- Includes a simple in-game GUI (`/whdc gui`) with **Run** and **Test** buttons.

## Commands

- `/whdc` (help)
- `/whdc pwd <password> [channel]`
- `/whdc store <name> <payload>`
- `/whdc list`
- `/whdc send <name>`
- `/whdc pull <name>`
- `/whdc test`
- `/whdc sync <channel_name> [channel_pass]`
- `/whdc ipc <COMMAND> [payload]`
- `/whdc gui`

## Install

Copy this folder into your WoW `Interface/AddOns/` directory and ensure the folder name matches the addon name if your loader requires it.
