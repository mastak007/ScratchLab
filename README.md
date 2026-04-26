# ScratchLab 🎛️

**Master the Art of Turntablism**

ScratchLab is an iOS app that teaches DJs how to scratch through gamified practice sessions, AI battles, and online head-to-head competitions.

---

## 🎯 Features

### Practice Mode
- **20 Scratches** across 5 difficulty levels
- Real-time audio analysis with pattern matching
- Camera feed with gamification overlays
- ML-powered equipment detection (turntables/controllers)
- Progress tracking and mastery system

### Scratch Curriculum

| Level | Name | Scratches | Focus |
|-------|------|-----------|-------|
| 1 | Foundation | Baby, Forward, Backward, Release | Record movement basics |
| 2 | Control | Tear, Chirp, Scribble, Stab | Precision & fader intro |
| 3 | Fader Mastery | Transform, Crab, 1-Click Flare, Orbit | Advanced fader work |
| 4 | Advanced | 2-Click Flare, Twiddle, Boomerang, Hydroplane | Complex techniques |
| 5 | Master | 3-Click Flare, Autobahn, Military, Prizm | Competition level |

### Progression System
- Master all 4 scratches in a level (90% accuracy)
- Complete the level's combo challenge
- Unlock next level with new AI opponent

### Battle Modes
- **AI Challenge**: Face off against 5 AI characters
- **Online Battle**: 90-second turn-based rounds (async)
- Emoji avatar overlays hide real body/face

---

## 📁 Project Structure

```
ScratchLab/
├── ScratchLabApp.swift          # App entry point
├── Info.plist                   # App configuration & permissions
│
├── Models/
│   ├── Scratch.swift            # 20 scratch definitions
│   └── GameState.swift          # Game state management
│
├── Views/
│   ├── MainMenuView.swift       # Main menu UI
│   ├── LevelSelectView.swift    # Level selection
│   └── PracticeModeView.swift   # Practice session UI
│
├── Audio/
│   ├── AudioEngine.swift        # Audio capture & analysis
│   ├── SampleManager.swift      # Scratch samples (Fresh, Ahhh, etc.)
│   └── BackingTrackManager.swift # Beat/backing tracks
│
├── Detection/
│   └── EquipmentDetector.swift  # ML turntable/controller detection
│
├── Services/
│   └── ProgressManager.swift    # Progress & persistence
│
└── Assets.xcassets/             # App icons, colors
```

---

## 🛠 Setup Instructions

### 1. Open the Xcode Project

1. Double-click `ScratchLab.xcodeproj` to open in Xcode
2. Bundle ID is pre-configured: `com.machelpnz.scratchlab` ✅
3. Select your Development Team in Signing & Capabilities

### 2. Add Your Audio Resources

Add your scratch audio/video dataset to the project:

### 3. Replace Info.plist

Replace the generated `Info.plist` with the one from this project (contains required permissions).

### 4. Copy Assets

Copy the `Assets.xcassets` folder contents to your project.

### 5. Add Audio Resources

Create these folders and add audio files:
- `Resources/Samples/` - Scratch samples (fresh.wav, ahhh.wav, etc.)
- `Resources/BackingTracks/` - Beat loops (boom_bap_90bpm.mp3, etc.)
- `Resources/Tutorials/` - Tutorial videos

### 6. Add Frameworks

In Xcode → Target → General → Frameworks:
- AVFoundation (included by default)
- Vision
- CoreML
- GameKit

### 7. Configure Capabilities

In Xcode → Target → Signing & Capabilities:
- Add **Game Center**
- Add **Background Modes** → Audio

---

## 📱 Required Permissions

| Permission | Reason |
|------------|--------|
| Microphone | Analyze scratching audio |
| Camera | Detect equipment, display overlays |
| Photo Library | Save/share battle recordings |

---

## 🎵 Audio Setup

### Input Options
1. **Phone Microphone** - Point at DJ setup
2. **Line In** - Connect audio interface
3. **DJ App Routing** - Inter-app audio from Serato/Traktor/etc.

### Scratch Samples (User loads in DJ software)
- Fresh
- Ahhh
- Ah Yeah
- Wickid
- (and more...)

### Backing Tracks (App provides)
- Boom Bap (90-95 BPM)
- Electro (100-105 BPM)
- Trap (110-140 BPM)
- Drum & Bass (120-174 BPM)
- House (120-128 BPM)
- Breakbeat (100-130 BPM)

---

## 🎮 Game Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Level 1    │────▶│  Level 2    │────▶│  Level 3    │──▶ ...
│  Foundation │     │  Control    │     │  Fader      │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ 4 Scratches │     │ 4 Scratches │     │ 4 Scratches │
│ (choose any)│     │ (choose any)│     │ (choose any)│
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│Master each  │     │Master each  │     │Master each  │
│at 90% acc   │     │at 90% acc   │     │at 90% acc   │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ COMBO       │     │ COMBO       │     │ COMBO       │
│ CHALLENGE   │     │ CHALLENGE   │     │ CHALLENGE   │
└─────────────┘     └─────────────┘     └─────────────┘
```

---

## 🏆 Scoring

| Factor | Weight |
|--------|--------|
| Pattern Accuracy | 30% |
| Timing (on beat) | 25% |
| Frequency Match | 20% |
| Rhythm Pattern | 25% |

### Streak Bonus
- Each consecutive 70%+ attempt increases multiplier by 10%
- Breaking streak resets multiplier

---

## 🤖 AI Characters

| Character | Level | Skill |
|-----------|-------|-------|
| DJ Rookie 🎧 | 1 | 60% |
| Flash Gordon ⚡️ | 2 | 75% |
| MC Cipher 🎤 | 3 | 85% |
| DJ Nova 🌟 | 4 | 92% |
| Grand Master L 👑 | 5 | 98% |

---

## 📝 TODO (Future Features)

- [ ] Train CoreML model for equipment detection
- [ ] Real-time multiplayer with WebRTC
- [ ] Hand tracking for fader visualization
- [ ] Apple Watch companion app
- [ ] Record and share scratch clips
- [ ] Community challenges & leaderboards

---

## 📄 License

© 2024 - All rights reserved.

---

## 🙏 Credits

Scratch sample dataset and tutorial videos courtesy of the DJ community.

---

**Built with ❤️ for the turntablism community**
