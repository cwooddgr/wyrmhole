# Wyrmhole

![Wyrmhole](assets/wyrmhole-hero.png)

A local network video portal between two iPads. Creates a persistent, full-screen video/audio connection that acts like a window between two rooms.

## Requirements

- Two iPads running iPadOS 16.0+
- Both devices on the same local network
- Xcode 15+ (for building)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)

## Building

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate Xcode project
cd /path/to/wyrmhole
xcodegen generate

# Open in Xcode
open Wyrmhole.xcodeproj
```

Then in Xcode:
1. Select your Development Team in Signing & Capabilities
2. Connect an iPad and build/run
3. Repeat for the second iPad

## Usage

1. Launch Wyrmhole on both iPads
2. On one device, tap the eye icon (or "Make this device visible") to advertise
3. The other device will see it appear in the list
4. Tap to connect
5. Full-screen video portal opens automatically

Tap anywhere on the portal view to show controls, including the disconnect button.

## Architecture

```
Wyrmhole/
├── WyrmholeApp.swift           # App entry point
├── Models/
│   └── Peer.swift              # Discovered device model
├── Views/
│   ├── ContentView.swift       # Root view / state router
│   ├── DiscoveryView.swift     # Browse and advertise UI
│   └── PortalView.swift        # Full-screen video portal
└── Services/
    ├── BonjourService.swift    # Network discovery via Bonjour
    ├── WebRTCService.swift     # Video/audio streaming
    └── ConnectionManager.swift # Connection lifecycle orchestration
```

## How It Works

- **Discovery**: Uses Bonjour (Network.framework) to advertise and discover nearby Wyrmhole devices on the local network
- **Signaling**: WebRTC offer/answer and ICE candidates are exchanged over a direct TCP connection established via Bonjour
- **Media**: WebRTC handles video/audio capture, encoding, and low-latency peer-to-peer streaming
- **Reconnection**: Automatic reconnect with exponential backoff if the connection drops

## Permissions

The app requires:
- **Camera** - to capture video
- **Microphone** - to capture audio
- **Local Network** - to discover and connect to other devices

## License

MIT License - Copyright (c) 2026 DGR Labs, LLC
