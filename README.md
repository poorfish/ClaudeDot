# Claude Dot

A macOS menu bar utility that monitors Claude Code sessions in real-time. A small colored dot in your status bar tells you exactly what Claude is doing — thinking, writing code, running tools, or waiting for your input.

## Features

- Real-time status monitoring via transcript event stream parsing
- Animated status bar dot with distinct colors and animations per state
- Audio notifications for key state transitions
- Left-click to activate Claude Code terminal; right-click for settings
- Auto-configures Claude Code statusLine hook and notification hook on first launch
- Supports Ghostty, iTerm2, Warp, and Terminal

## Status States

Claude Dot distinguishes six fine-grained states:

| Status | Label | Color | Animation | Sound | Detection Method |
|--------|-------|-------|-----------|-------|-----------------|
| **Disconnected** | 未连接 | Gray `#78787D` | Static, dim (0.3 opacity) | "Basso" | No alive Claude Code process found |
| **Waiting for Input** | 等待输入 | Green `#50B450` | Gentle breathing (3s cycle) | "Pop" (only when returning from working) | Process alive + statusLine refreshing + no recent transcript activity |
| **Thinking** | 思考中 | Purple `#A78BFA` | Soft pulse (2s cycle) | Silent | Latest transcript event is `assistant/thinking` |
| **Responding** | 生成回复 | Blue `#60A5FA` | Medium pulse (1.5s cycle) | Silent | Latest transcript event is `assistant/text` |
| **Tool Active** | 执行工具 | Orange `#D77757` | Fast pulse (1s cycle) | "Tink" | `tool_use` event without matching `tool_result` |
| **Awaiting Permission** | 等待授权 | Yellow `#FBBF24` | Blink on/off (0.8s cycle) | "Submarine" | Notification hook marker or heuristic (pending tool + 3s inactivity) |

### Sound Design

- **Thinking & Responding** are silent because they toggle frequently during normal work
- **Awaiting Permission** plays a noticeable alert because it requires user action
- **Pop** only plays when transitioning from a working state back to idle, signaling task completion

## How It Works

Claude Dot combines three signal sources for accurate status detection:

### 1. Transcript JSONL (Primary Signal)

Claude Code writes every event (thinking, text generation, tool calls, tool results) to a per-session `.jsonl` transcript file. Claude Dot tails this file and parses new events in near real-time (~0.5s polling), maintaining a state machine that tracks pending tool executions and the latest event type.

### 2. StatusLine File (Idle Detection)

A statusLine hook in `~/.claude/settings.json` runs a script every 3 seconds **only when Claude Code is idle**. Claude Dot checks the modification time of `~/.claude/claudedot-status.json` — if it's fresh (<5s), Claude is idle. This file also provides the `transcript_path` to locate the correct JSONL file.

### 3. Notification Hook (Permission Detection)

A Notification hook writes to `~/.claude/claudedot-notification.json` when Claude Code triggers a notification (e.g., permission prompt). Claude Dot monitors this marker file to detect the awaiting permission state precisely.

### Priority Resolution

When multiple signals are present, status is resolved by priority:

1. Process not found → **Disconnected**
2. Notification marker fresh → **Awaiting Permission**
3. Pending tool_use + 3s inactivity + statusLine stale → **Awaiting Permission** (heuristic)
4. Pending tool_use → **Tool Active**
5. Recent transcript `thinking` → **Thinking**
6. Recent transcript `text` → **Responding**
7. StatusLine fresh → **Waiting for Input**
8. StatusLine stale + no transcript → **Thinking** (API call in progress)

## Requirements

- macOS 26.3 (Tahoe) or later
- Claude Code CLI installed with an active session

## Installation

1. Open the Xcode project in `ClaudeDot/`
2. Build and run (Cmd+R)
3. Claude Dot appears as a dot in your menu bar
4. On first launch, it auto-configures:
   - `~/.claude/claudedot-statusline.sh` — statusLine hook script
   - `~/.claude/claudedot-notify.sh` — notification hook script
   - `~/.claude/settings.json` — adds `statusLine` and `hooks.Notification` entries

## Usage

- **Left-click** the dot to switch to your Claude Code terminal
- **Right-click** to open the settings popover (status info, sound toggle, terminal selector)

## Project Structure

```
ClaudeDot/
├── ClaudeDot/
│   ├── ClaudeDotApp.swift    # Entire application (~830 lines)
│   ├── Info.plist             # LSUIElement=true (background app)
│   └── Assets.xcassets/       # App icon and colors
└── ClaudeDot.xcodeproj/
```

## License

MIT
