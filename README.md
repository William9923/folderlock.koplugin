# folderlock.koplugin

## Overview

`folderlock.koplugin` adds password protection to folders in KOReader's File Manager, so locked folders ask for a password before they can be opened.

## Demo / Screenshot

<!-- Screenshot placeholder: add image manually -->
<!-- Example: ![FolderLock demo](docs/screenshots/folderlock-demo.png) -->

TODO

## Philosophy & Scope

folderlock.koplugin is designed to be a privacy barrier, not a software fortress. Its primary goal is to keep casual snoopers (friends, family, or kids) out of specific folders with zero configuration overhead, while ensuring your library remains fundamentally safe.

**Intuitively Native:** No complex dashboards. It integrates seamlessly into KOReader's existing long-press menus and standard keyboard prompts.

**Fail-Safe Security:** Your files are never encrypted or modified. This eliminates any risk of file corruption or permanent lockouts if the plugin is uninstalled or encounters an error.

**Invisible Performance:** Completely event-driven. It uses lightweight path-matching logic that won't drain your e-reader's battery or slow down navigation.

⚠️ **Note on Security:** This is an application-level UI lock. It blocks access entirely within KOReader, but files will still be visible normally if you connect your e-reader to a computer via USB.

## Features

- Lock any folder directly from KOReader's menu
- Unlock a folder from the same menu
- Password prompt when opening locked folders
- Parent locks cascade to subfolders automatically

## Installation Guide (WIP)

1. Download the latest `folderlock.koplugin` release package.
2. Extract the archive.
3. Copy `folderlock.koplugin/` into your KOReader `plugins/` directory.
4. Restart KOReader.

## Usage

1. Open KOReader File Manager and go to the folder you want to protect.
2. Open the menu and choose **Folder Lock**.
3. Set a password when prompted.
4. Try opening the locked folder again and enter the password.

<!-- Usage screenshot placeholder -->
<!-- Example: ![Lock flow](docs/screenshots/folderlock-usage.png) -->
