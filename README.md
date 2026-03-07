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
- Sends and validates signed IPC lines over the WoW addon channel.
- Persists sync settings and password in `WHDC_DB` SavedVariables (`WTF`).
- Rejects malformed/unsigned/replayed frames.
- Handles baseline protocol commands like `PING`/`PONG` and `CHANNEL`/`CHANNEL_ACK`.
- Includes an in-game GUI (`/whdc gui`) with saved inputs for **channel name**, **channel password**, and **IPC password**, plus **Save/Join/Test** actions.

## Commands

- `/whdc` (help)
- `/whdc test` (queues a signed `PING` frame onto the configured sync channel)
- `/whdc sync <channel_name> [channel_pass]`
- `/whdc gui`

## Install

Copy this folder into your WoW `Interface/AddOns/` directory and ensure the folder name matches the addon name if your loader requires it.
