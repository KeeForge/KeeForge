# Roadmap

This file tracks planned product work.

## Synchronization Support

- [ ] support Google Drive
- [x] support OneDrive
- [x] support WebDAV

## iPad and macOS Support

- [ ] Plan and implement native macOS support — implemented and building/testing green, but ON HOLD and unreleased (see CHANGELOG's "macOS App" section)
- [x] Build an iPad-native layout

## Core Functionalities

### Passkey Creation

- [ ] Passkey creation (Phase 3; requires KDBX write support)

### Database Creation

- [x] Create new databases directly in the app

## In-App UI Enhancements

- [ ] optimize database row view
- [x] nicer password views with consistent font/color and strength indication
- [x] add folders in settings page
- [x] group settings into sub pages
- [x] option to disable metadata display for DB row

### Tags

- [ ] Tag integration: tag browser, tag search, group-tag inheritance, editor tag suggestions (spec: `docs/specs/2026-07-19-tag-integration/`)

### Entry Viewer

- [ ] Add an in-app entry history viewer and restore flow

### Attachments

- [x] Add in-app attachment browsing (read-only viewing, preview, share)
- [ ] Add attachment management (add, rename, delete)
- [ ] Support attachment sync across storage providers

## Localization Support

- [x] Add internationalization infrastructure across the app
- [x] Add German language support

## Release
- [ ] Github release for macOS app
