// CButterfield27
// Call of Duty: Black Ops (Plutonium) autosplitter
//
// (Alive, Dead) values.
//   All maps:      Alive=0,  Dead=5
//   Verrückt:      Alive=7,  Dead=25
//   Der Riese:     Alive=129,Dead=26
//
// menu_state values:
//   MENU_STATE_PLAYING = 0
//   MENU_STATE_MAIN    = 99
// timer: ~20 units/sec, resets near 0 (map restart makes it drop/reset)
// game_paused: > 0 = paused, 0 = playing

const int MENU_STATE_PLAYING = 0;
const int MENU_STATE_MAIN    = 99;

const int MENU_STATE_ADDR  = 0x7CB530;
const int TIMER_ADDR       = 0x168A37C;
const int GAME_PAUSED_ADDR = 0x216BFD0;
const int DEAD_ADDR        = 0x1656C38;

state("plutonium-bootstrapper-win32")
{
    int  menu_state  : MENU_STATE_ADDR;
    int  timer       : TIMER_ADDR;
    int  game_paused : GAME_PAUSED_ADDR;
    int  dead        : DEAD_ADDR;
}

init { refreshRate = 20; }

settings
{
    // ---- Tunables ----
    "T_START_THRESHOLD"     : 50
    "T_RESET_SMALL"         : 100
    "PauseConfirmTicks"     : 3
    "UseStallPause"         : false
    "T_TIMER_STALL_TICKS"   : 3
    "T_RESUME_TICKS"        : 2
}

startup
{
    // ---- Tunables ----
    vars.T_START_THRESHOLD       = (int)settings["T_START_THRESHOLD"];     // start once in-game timer >= 50 (~2.5s @ ~20/s)
    vars.T_RESET_SMALL           = (int)settings["T_RESET_SMALL"];         // "fresh" timer threshold for menu-based detection
    vars.T_RESET_CONFIRM_TICKS   = 20;   // ~1s 20 Hz (menu-based fresh-game arm)

    vars.PauseConfirmTicks       = (int)settings["PauseConfirmTicks"];     // debounce explicit pause
    vars.UnpauseConfirmTicks     = 3;    // debounce explicit unpause

    // Death handling (debounce)
    vars.DeathConfirmTicks       = 5;    // ~250ms to confirm death
    vars.AliveConfirmTicks       = 5;    // ~250ms alive confirm before allowing new start

    // Stall-based pause (kept OFF for better pause behavior)
    vars.UseStallPause           = (bool)settings["UseStallPause"];
    vars.T_TIMER_STALL_TICKS     = (int)settings["T_TIMER_STALL_TICKS"];
    vars.T_RESUME_TICKS          = (int)settings["T_RESUME_TICKS"];

    // ---- Timer model + flags ----
    vars.timerModel = new TimerModel { CurrentState = timer };
    vars.is_paused = (vars.timerModel.CurrentState.CurrentPhase == TimerPhase.Paused);
    vars.timer_started = false;

    // Pause-stripped clock (optional)
    vars.timer_value = 0;
    vars.timer_pause_length = 0;

    // Debounce / bookkeeping
    vars.pauseHold = 0;
    vars.unpauseHold = 0;
    vars.stallTicks = 0;
    vars.resumeTicks = 0;
    vars.stallPauseActive = false;

    vars.pendingReset = false;
    vars.did_reset = false;

    vars.deathStableTicks = 0;
    vars.aliveStableTicks = 0;
    vars.freshGameConfirmTicks = 0;

    // Flow guards
    vars.hasStoppedOnce = false;
    vars.blockStartUntilAlive = false; // set on death; cleared after alive confirmed

    // ---- Map alive/death codes ----
    // Alive values across maps
    vars.AliveVals = new HashSet<int> { 0, 7, 129 };
    // Dead values across maps
    vars.DeadVals  = new HashSet<int> { 5, 25, 26 };
}

// Start — only when alive, in gameplay, and timer is moving
start
{
    if (vars.pendingReset) return false;                       // don't start while a reset is queued
    if (vars.blockStartUntilAlive || !vars.AliveVals.Contains(current.dead)) return false; // must be alive
    if (current.menu_state != MENU_STATE_PLAYING) return false; // must be in gameplay

    if (current.timer > old.timer && current.timer >= vars.T_START_THRESHOLD)
    {
        vars.timer_started = true;
        vars.is_paused = false;
        vars.hasStoppedOnce = false;
        vars.pauseHold = vars.unpauseHold = 0;
        return true;
    }
    return false;
}

// Base script: no splits
split { return false; }

// Reset — executes only when update() sets vars.pendingReset (menu/death path)
reset
{
    if (vars.pendingReset)
    {
        // Clear local state
        vars.timer_started = false;
        vars.is_paused = false;

        vars.timer_value = 0;
        vars.timer_pause_length = 0;

        vars.pauseHold = vars.unpauseHold = 0;
        vars.stallTicks = vars.resumeTicks = 0;
        vars.stallPauseActive = false;

        // Keep aliveStableTicks/blockStartUntilAlive (death path) as-is;
        // we want to require a stable alive state before re-starting.
        vars.deathStableTicks = 0;
        vars.freshGameConfirmTicks = 0;

        vars.pendingReset = false;
        vars.did_reset = true;
        vars.hasStoppedOnce = false;
        return true;
    }

    if (current.menu_state != MENU_STATE_PLAYING || current.timer > vars.T_RESET_SMALL)
        vars.did_reset = false;

    return false;
}

// 1) Debounced pause/unpause from explicit pause flag (>0 = paused)
bool handlePauseToggle(bool toggledThisTick)
{
    if (!vars.timer_started)
        return toggledThisTick;

    bool gameIsPaused = (current.game_paused > 0);

    if (gameIsPaused) { vars.pauseHold++;  vars.unpauseHold = 0; }
    else              { vars.unpauseHold++; vars.pauseHold  = 0; }

    if (!vars.is_paused && vars.pauseHold >= vars.PauseConfirmTicks)
    {
        vars.timerModel.Pause(); // ON
        vars.is_paused = true;
        vars.stallPauseActive = false;
        vars.stallTicks = vars.resumeTicks = 0;
        toggledThisTick = true;
    }

    if (!toggledThisTick && vars.is_paused && !vars.stallPauseActive &&
        vars.unpauseHold >= vars.UnpauseConfirmTicks)
    {
        vars.timerModel.Pause(); // OFF
        vars.is_paused = false;
        toggledThisTick = true;
    }

    return toggledThisTick;
}

// 2) Stall-based pause (off unless enabled)
bool handleStallPause(bool toggledThisTick)
{
    if (!(vars.UseStallPause && vars.timer_started && !toggledThisTick && (current.game_paused == 0)))
        return toggledThisTick;

    if (current.timer <= old.timer) vars.stallTicks++; else { vars.stallTicks = 0; vars.resumeTicks = 0; }

    if (!vars.is_paused && vars.stallTicks >= vars.T_TIMER_STALL_TICKS)
    {
        vars.timerModel.Pause(); // ON
        vars.is_paused = true;
        vars.stallPauseActive = true;
        vars.resumeTicks = 0;
        return true;
    }

    if (vars.is_paused && vars.stallPauseActive && current.timer > old.timer)
    {
        vars.resumeTicks++;
        if (vars.resumeTicks >= vars.T_RESUME_TICKS)
        {
            vars.timerModel.Pause(); // OFF
            vars.is_paused = false;
            vars.stallPauseActive = false;
            vars.stallTicks = vars.resumeTicks = 0;
            return true;
        }
    }

    return toggledThisTick;
}

// 4) Stop on death → pause + queued reset; block starts until alive confirmed
void checkDeathReset()
{
    if (vars.timer_started)
    {
        bool isDeadNow = vars.DeadVals.Contains(current.dead);
        if (isDeadNow) vars.deathStableTicks++; else vars.deathStableTicks = 0;

        if (vars.deathStableTicks >= vars.DeathConfirmTicks)
        {
            if (!vars.is_paused) { vars.timerModel.Pause(); vars.is_paused = true; } // freeze immediately
            vars.timer_started = false;
            vars.hasStoppedOnce = true;
            vars.pendingReset = true; // reset via reset{}
            vars.deathStableTicks = 0;
            vars.pauseHold = vars.unpauseHold = 0;

            vars.blockStartUntilAlive = true; // don't allow start until alive again
            vars.aliveStableTicks = 0;
        }
    }
}

// Update — pause/unpause, stop on death/menu, HARD reset on map restart, arm resets
update
{
    // 0) Track alive stability to clear start-block after death
    if (vars.AliveVals.Contains(current.dead))
    {
        vars.aliveStableTicks++;
        if (vars.blockStartUntilAlive && vars.aliveStableTicks >= vars.AliveConfirmTicks)
            vars.blockStartUntilAlive = false; // allow future starts again
    }
    else
    {
        vars.aliveStableTicks = 0;
    }

    bool toggledThisTick = false;
    toggledThisTick = handlePauseToggle(toggledThisTick);
    toggledThisTick = handleStallPause(toggledThisTick);

    // 3) Stop on leaving gameplay (menu_state != MENU_STATE_PLAYING) → pause + queued reset
    if (vars.timer_started && current.menu_state != MENU_STATE_PLAYING)
    {
        if (!vars.is_paused) { vars.timerModel.Pause(); vars.is_paused = true; } // freeze immediately
        vars.timer_started = false;
        vars.hasStoppedOnce = true;
        vars.pendingReset = true;   // reset via reset{} next tick
        vars.pauseHold = vars.unpauseHold = 0;
    }

    // 4) Stop on death → pause + queued reset; block starts until alive confirmed
    checkDeathReset();

    // 4b) HARD map restart: timer decreased while still in gameplay (reset even at 1–2s)
    if (current.menu_state == MENU_STATE_PLAYING && current.timer < old.timer)
    {
        // Immediate LiveSplit reset to 0.00
        vars.timerModel.Reset();

        // Clear local state for a fresh attempt
        vars.timer_started = false;
        vars.is_paused = false;
        vars.hasStoppedOnce = false;
        vars.did_reset = true;

        vars.pauseHold = vars.unpauseHold = 0;
        vars.stallTicks = vars.resumeTicks = 0;
        vars.stallPauseActive = false;
        vars.freshGameConfirmTicks = 0;

        // If restart followed a death, start is still gated by blockStartUntilAlive.
    }

    // 5) Fresh-game queued reset logic — kept for menu-based reloads only
    if (!vars.timer_started && vars.hasStoppedOnce &&
        !vars.pendingReset && !vars.did_reset &&
        current.menu_state == MENU_STATE_PLAYING && current.timer <= vars.T_RESET_SMALL)
    {
        vars.freshGameConfirmTicks++;
        if (vars.freshGameConfirmTicks >= vars.T_RESET_CONFIRM_TICKS)
        {
            vars.pendingReset = true;     // reset via reset{}
            vars.hasStoppedOnce = false;
            vars.freshGameConfirmTicks = 0;
        }
    }
    else if (current.timer > vars.T_RESET_SMALL || current.menu_state != MENU_STATE_PLAYING || vars.pendingReset || vars.did_reset)
    {
        if (!vars.timer_started)
            vars.freshGameConfirmTicks = 0;
    }

    // 6) Pause-stripped clock
    if (!vars.is_paused)
        vars.timer_value = current.timer - vars.timer_pause_length;
    else
        vars.timer_pause_length = current.timer - vars.timer_value;

    return true;
}
