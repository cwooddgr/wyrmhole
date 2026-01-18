# Claude Code Guidelines for Wyrmhole

## Project Overview

Wyrmhole is an iOS app that creates a persistent video/audio portal between two iPads on the same local network. It uses WebRTC for media streaming and Bonjour for device discovery.

## Build Commands

```bash
# Generate Xcode project (required after modifying project.yml)
xcodegen generate

# Build from command line
xcodebuild -project Wyrmhole.xcodeproj -scheme Wyrmhole -destination 'generic/platform=iOS' build
```

## Architecture

- **WyrmholeApp.swift** - App entry point, initializes device orientation notifications
- **ConnectionManager.swift** - Orchestrates connection lifecycle, signaling protocol, reconnection logic
- **BonjourService.swift** - Bonjour advertising/discovery using Network.framework
- **WebRTCService.swift** - WebRTC peer connection, video/audio capture and streaming
- **Views/** - SwiftUI views (ContentView, DiscoveryView, PortalView)
- **Views/Effects/** - Portal transition effect using CAEmitterLayer particles

## Key Technical Details

### Network Connections
- Discovery uses peer-to-peer Bonjour (`includePeerToPeer = true` on browser)
- Signaling TCP connections use WiFi only (no `includePeerToPeer`) for iOS 16 compatibility
- AWDL (Apple Wireless Direct Link) is unreliable between iOS 16 and newer versions

### Threading
- ConnectionManager is `@MainActor` isolated
- NWConnection uses a dedicated `connectionQueue` for connection operations
- State updates are dispatched to main queue for UI updates
- Use `DispatchQueue.main.async` instead of `Task { @MainActor in }` for iOS 16 compatibility

### Signaling Protocol
Messages are length-prefixed JSON over TCP:
- `hello(String)` - Exchange display names
- `sdp(RTCSessionDescriptionWrapper)` - SDP offer/answer
- `iceCandidate(RTCIceCandidateWrapper)` - ICE candidates
- `disconnect` - Graceful disconnect notification

### WebRTC Configuration
- No STUN/TURN servers (local network only)
- Uses unified plan SDP semantics
- H.264, VP8, VP9, AV1 video codecs supported
- Opus audio codec

## Common Issues

### iOS 16 Compatibility
- Avoid `Task { @MainActor in }` - use `DispatchQueue.main.async` instead
- Don't use AWDL for signaling connections (causes "Connection refused" errors)
- The deprecated `onChange(of:perform:)` syntax is required for iOS 16

### Camera Orientation
- Device orientation notifications must be started at app launch
- Camera capture is restarted on orientation change to pick up correct orientation
- A 0.5s delay restart is used on first launch to ensure correct initial orientation

### Portal Transition Effect
- Uses CAEmitterLayer with CADisplayLink for frame-by-frame animation (CABasicAnimation doesn't work for emitterSize)
- Iris effect uses CAShapeLayer with `fillRule = .evenOdd` to create a circular hole in a black layer
- Particle birth rate scales dynamically with radius to maintain edge coverage as circumference grows
- Animation deferred until layoutSubviews provides valid bounds to ensure correct centering
- ConnectionManager.portalTransitionState coordinates animation timing with disconnect flow

## Testing

Test connections between devices running different iOS versions (16, 17, 26) to ensure compatibility. The iOS 16 device as initiator is the most sensitive to connection issues.
