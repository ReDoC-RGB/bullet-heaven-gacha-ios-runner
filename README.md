# Rivetkind iOS Build Runner

Infrastructure only: no game source, assets, generated Xcode project or signing credentials are public.

The manual TestFlight workflow is bound to Rivetkind 1.117 Build 118. It downloads one temporary bearer-protected export, verifies its full file inventory and hash-pinned release authority, archives on macOS with Xcode 26, validates the signature and Apple submission, and uploads to TestFlight. No public App Store review or release is performed.

Legacy Ad Hoc and external-beta scripts remain historical and must not be dispatched for Build 118. Final beta assignment uses the existing Rivetkind group after Apple processing.
