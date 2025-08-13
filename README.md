# Call of Duty: Black Ops (Plutonium) Autosplitter

**Author:** CButterfield27  
**Game:** Call of Duty: Black Ops (Zombies mode via Plutonium)  
**Purpose:** Automatically start, pause, unpause, stop, and reset LiveSplit timing based on in-game state.

---

## Features

- **Automatic Start**: Begins timing shortly after entering gameplay, once the in-game timer has moved past a small threshold.
- **Automatic Pause/Unpause**: Detects explicit in-game pause states and stops LiveSplit without affecting the in-game clock.
- **Automatic Stop**: Stops the timer when the player dies or returns to the menu.
- **Automatic Reset**:
  - On death, queues a reset for the next run.
  - On map restart (even if only 1–2 seconds in), immediately resets LiveSplit to `0.00`.
- **Multi-Map Death Detection**: Supports map-specific alive/dead values for all Zombies maps.

---

## Memory Offsets

The script reads memory directly from the `plutonium-bootstrapper-win32` process:

| Variable       | Address     | Description |
|----------------|-------------|-------------|
| `menu_state`   | `0x7CB530`  | 0 = playing, 99 = menu |
| `timer`        | `0x168A37C` | Rises ~20 units/sec while in-game, resets near 0 |
| `game_paused`  | `0x216BFD0` | >0 = paused, 0 = playing |
| `dead`         | `0x1656C38` | Alive/Dead values vary by map (see below) |

---

## Death Detection by Map

| Map              | Alive Value | Dead Value |
|------------------|-------------|------------|
| All other maps   | 0           | 5          |
| Verrückt         | 7           | 25         |
| Der Riese        | 129         | 26         |

The script checks against **all alive values** and **all dead values** for universal compatibility.

---

## Timer Behavior Overview

**Start Condition:**
- `menu_state` = 0 (in gameplay)
- `dead` matches any alive value
- `timer` increasing and ≥ start threshold

**Pause Condition:**
- `game_paused` > 0 for 3 ticks (~150ms)

**Unpause Condition:**
- `game_paused` = 0 for 3 ticks (~150ms)

**Stop Condition:**
- Player dies (dead value detected for 5 ticks)
- Player leaves gameplay (`menu_state` != 0)

**Reset Conditions:**
1. **Queued Reset** — Occurs after stop due to death or menu exit.
2. **Hard Reset** — Immediate reset if `timer` decreases while still in gameplay (map restart).

---

## Tunable Variables

You can adjust these in the `startup` block:

- `T_START_THRESHOLD`: In-game timer value to start at (default: 50)
- `PauseConfirmTicks` & `UnpauseConfirmTicks`: Debounce for pause/unpause
- `DeathConfirmTicks`: Time to confirm death
- `AliveConfirmTicks`: Time to confirm alive before allowing restart
- `UseStallPause`: Optional pause when timer stalls
- `T_TIMER_STALL_TICKS` & `T_RESUME_TICKS`: Stall pause settings

---

## Usage

1. Open LiveSplit.
2. Load this `.asl` script in **Edit Layout** → **Add Control** → **Add Control** → **Scriptable Auto Splitter** → **Add B01 Auto Splitter (plutonium).asl**.
3. Ensure the game is running through Plutonium.
4. The script will automatically start, pause, unpause, stop, and reset as you play.
5. You will need to split manually.

---

## Notes

- This script is designed for **Plutonium** and may require new offsets if the game updates.
- If testing on base BO1, offsets will differ and need updating.
- Designed specifically for Zombies mode but may work with campaign/custom maps if `menu_state`, `timer`, and `dead` behave similarly.

---
