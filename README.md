# Rivetkind iOS Build Runner

This public repository contains infrastructure only. It has no application source, Unity project, generated Xcode project, game asset, signing material, APK, or IPA.

The manual workflows use a standard GitHub-hosted `macos-26` runner and fail closed unless Xcode 26 with the iPhoneOS 26 SDK (or newer) is active. They download one private, hash-pinned Unity Xcode export; verify the detached manifest and complete archive inventory before extraction; import protected signing inputs into an ephemeral keychain; compile and sign one IPA; verify its identity and provenance; and destroy transient payload and signing state.

The workflows publish only bounded result or sanitized failure-diagnostic artifacts and have no automatic trigger. The currently authorized payload is Rivetkind v1.39 build 40.
