# Shared App Sources

The app-target map and cross-cutting flows live in [README.md](README.md). Read the owning subfolder's `AGENTS.md` before changing its code.

## Workflows

- App and Mac targets use folder globs in `../project.yml`; `xcodegen generate` picks up new files. The `KeeForgeAutoFill` and `KeeForgeMacAutoFill` shared-source allow-lists must stay byte-identical. Edit both together and keep shared imports/APIs extension-safe; read `../AutoFillExtension/AGENTS.md` when changing extension-shared code.
- For navigation, editor lifecycle, Settings effects, or launch/URL routing, read `ViewModels/AGENTS.md` even when changing a shell or view. It defines the reusable owners and their test contracts. Shared presentation rules live in `Views/README.md`; platform adapters live in `App/` and the relevant view folder.
- When adding or changing database creation, edit operations, KDBX parser/writer behavior, protected fields, unknown XML handling, AutoFill save, cloud save, or local save, update `../KeeForgeTests/KDBXCompatibilityTests.swift`. Update the compatibility artifact gate if the supported compatibility matrix changes; its workflow is in `../ci_scripts/README.md`.
