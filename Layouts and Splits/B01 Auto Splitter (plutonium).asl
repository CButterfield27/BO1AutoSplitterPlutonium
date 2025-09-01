// CButterfield27
// 08/31/2025
// Call of Duty: Black Ops (Plutonium) autosplitter
//
// Alive/Dead memory values per map:
//   All maps:      Alive=0,   Dead=5
//   Verrückt:      Alive=7,   Dead=25
//   Der Riese:     Alive=129, Dead=26
//
// menu_state: 0 = playing, 99 = main menu (treat any != 0 as menu/loading)
// timer: ~20 units/sec, resets near 0 on map restart (drops/rolls back)
// game_paused: > 0 = paused, 0 = playing

state("plutonium-bootstrapper-win32")
{
  int menu_state   : 0x7CB530;
  int timer        : 0x168A37C;
  int game_paused  : 0x216BFD0;
  int game_round   : 0x13C7DF60;
  int dead         : 0x1656C38;
  int selected_map : 0x899C38;
}

init
{
  refreshRate = 20;

  // 1=Rounds, 2=EE, 3=Super EE (multi-map)
  vars.Game_Type = 1;

  // Fresh-timer heuristics
  vars.T_RESET_SMALL = 100;
  vars.T_RESET_CONFIRM_TICKS = 20;
  vars.T_FAST_FRESH_PAD = 20; // small cushion for near-0 detection

  // Pause debounce
  vars.PauseConfirmTicks = 3;
  vars.UnpauseConfirmTicks = 3;

  // Timer model & flags
  vars.timerModel = new TimerModel { CurrentState = timer };
  vars.is_paused = (vars.timerModel.CurrentState.CurrentPhase == TimerPhase.Paused);
  vars.timer_started = false;

  // Debounce counters / flows
  vars.pauseHold = 0;
  vars.unpauseHold = 0;
  vars.pendingReset = false;
  vars.did_reset = false;
  vars.freshGameConfirmTicks = 0;
  vars.hasStoppedOnce = false;
  vars.blockStartUntilAlive = false;

  // Super EE (GT=3) helpers
  vars.lastSplitIndex = -1;       // detect manual split
  vars.ee_wait_for_resume = false;
  vars.manualSplitHold = 0;       // reassert pause for N ticks after split/death
  vars.ee_prev_map = -1;
  vars.ee_saw_map_change = false; // manual split requires map change
  vars.ee_saw_fresh_timer = false;
  vars.ee_require_map_change = false;

  // GT1/GT2 death/fast-restart gate (pause -> wait -> Reset -> allow start)
  vars.gt12_wait_restart = false;

  // Fast restart mode (use fast thresholds after death, manual split, or pause->restart)
  vars.fast_restart_mode = false;

  // Full-restart (Quit to menu then pick a map) detection
  vars.menu_action_armed = false;  // set on game_paused: 1 -> 2 from pause menu
  vars.full_restart_path = false;  // confirmed when we reach menu_state == 99 after 1 -> 2

  // ---------- GT1 Manual Round Split Settings ----------
  // Users can edit the list below to choose which rounds to split on.
  // Default placeholders:
  //   2 (sanity check), 5, 10, 15, 20
  vars.gt1_split_rounds = new List<int> { 2, 5, 10, 15, 20 };

  // (Optional) Add more rounds by appending values to the list, e.g.:
  // vars.gt1_split_rounds.Add(25);
  // vars.gt1_split_rounds.Add(30);
  //
  // Internal: rounds that have already split this run (cleared on Reset/Start).
  vars.gt1_split_done = new List<int>();

  // Stability
  vars.DeathConfirmTicks = 5;
  vars.AliveConfirmTicks = 5;
  vars.deathStableTicks = 0;
  vars.aliveStableTicks = 0;

  // Alive/Dead codes (All, Verrückt, Der Riese)
  vars.AliveVals = new List<int> { 0, 7, 129 };
  vars.DeadVals  = new List<int> { 5, 25, 26 };

  // Per-map start thresholds (selected_map -> timer)
  vars.start_times = new Dictionary<int, int>
  {
    {  9, 120 }, // Kino Der Toten
    { 14, 120 }, // Five
    { 19,  60 }, // Dead Ops Arcade
    { 24, 255 }, // Ascension
    { 32, 120 }, // Call of the Dead
    { 48, 125 }, // Shangri-La
    { 80, 125 }, // Moon
    {148, 120 }, // Nacht Der Untoten
    {216, 120 }, // Verrückt
    {284, 120 }, // Shi No Numa
    {352, 120 }  // Der Riese
  };

  // Fast-restart thresholds (initially half of normal; adjustable per map)
  vars.fast_start_times = new Dictionary<int, int>
  {
    {  9, 60 }, // Kino Der Toten
    { 14, 60 }, // Five
    { 19, 30 }, // Dead Ops Arcade
    { 24, 130 }, // Ascension
    { 32, 60 }, // Call of the Dead
    { 48, 63 }, // Shangri-La
    { 80, 63 }, // Moon
    {148, 60 }, // Nacht Der Untoten
    {216, 60 }, // Verrückt
    {284, 60 }, // Shi No Numa
    {352, 60 }  // Der Riese
  };
}

start
{
  // Block during GT1/GT2 post-death/fast-restart gate; require gameplay, alive,
  // timer advancing, per-map threshold (fast thresholds if fast_restart_mode).
  if ((vars.Game_Type != 3 && vars.gt12_wait_restart)
      || vars.pendingReset
      || vars.blockStartUntilAlive
      || !vars.AliveVals.Contains(current.dead)
      || current.menu_state != 0
      || current.timer <= old.timer)
    return false;

  var dict = vars.fast_restart_mode ? vars.fast_start_times : vars.start_times;

  int thr = dict.ContainsKey(current.selected_map)
    ? dict[current.selected_map]
    : -1;

  if (thr >= 0 && current.timer >= thr)
  {
    vars.timer_started = true;
    vars.is_paused = false;
    vars.hasStoppedOnce = false;
    vars.pauseHold = 0;
    vars.unpauseHold = 0;
    vars.lastSplitIndex = vars.timerModel.CurrentState.CurrentSplitIndex;

    // Clear path flags on start
    vars.fast_restart_mode = false;
    vars.menu_action_armed = false;
    vars.full_restart_path = false;

    // Clear GT1 round-split memory for new run
    if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();

    return true;
  }

  return false;
}

split
{
  // GT1 only: split on user-selected rounds (each round only once)
  if (vars.Game_Type == 1
      && vars.timer_started
      && current.menu_state == 0
      && current.game_round > old.game_round)
  {
    int r = current.game_round;

    if (vars.gt1_split_rounds.Contains(r) && !vars.gt1_split_done.Contains(r))
    {
      vars.gt1_split_done.Add(r);
      return true;
    }
  }

  return false;
}

reset
{
  // GT3: no auto-reset
  if (vars.Game_Type == 3)
    return false;

  if (vars.pendingReset)
  {
    vars.timer_started = false;
    vars.is_paused = false;
    vars.pauseHold = 0;
    vars.unpauseHold = 0;
    vars.deathStableTicks = 0;
    vars.freshGameConfirmTicks = 0;
    vars.pendingReset = false;
    vars.did_reset = true;
    vars.hasStoppedOnce = false;

    // Clear path flags on reset
    vars.menu_action_armed = false;
    vars.full_restart_path = false;

    // Reset GT1 split memory on reset
    if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();

    return true;
  }

  if (current.menu_state != 0 || current.timer > vars.T_RESET_SMALL)
    vars.did_reset = false;

  return false;
}

update
{
  // --- GT3 manual split: instant pause + hold; wait strict resume gates ---
  if (vars.Game_Type == 3)
  {
    int idx = vars.timerModel.CurrentState.CurrentSplitIndex;
    if (vars.lastSplitIndex < 0) vars.lastSplitIndex = idx;

    if (idx > vars.lastSplitIndex)
    {
      if (!vars.is_paused) { vars.timerModel.Pause(); vars.is_paused = true; }
      vars.ee_wait_for_resume = true;
      vars.manualSplitHold = 2;
      vars.ee_prev_map = current.selected_map;
      vars.ee_saw_map_change = false;
      vars.ee_saw_fresh_timer = false;
      vars.ee_require_map_change = true;
      vars.fast_restart_mode = true; // use fast thresholds on resume
      vars.pauseHold = 0;
      vars.unpauseHold = 0;
    }

    vars.lastSplitIndex = idx;

    if (vars.manualSplitHold > 0)
    {
      if (!vars.is_paused) { vars.timerModel.Pause(); vars.is_paused = true; }
      vars.manualSplitHold--;
    }
  }

  // --- Unified death handling (all GT): pause then branch GT3 vs GT1/2 ---
  if (vars.timer_started)
  {
    if (vars.DeadVals.Contains(current.dead)) vars.deathStableTicks++;
    else vars.deathStableTicks = 0;

    if (vars.deathStableTicks >= vars.DeathConfirmTicks)
    {
      if (!vars.is_paused) { vars.timerModel.Pause(); vars.is_paused = true; }

      // common seeds for death path
      vars.ee_prev_map = current.selected_map;
      vars.ee_saw_map_change = false;
      vars.ee_saw_fresh_timer = false;
      vars.manualSplitHold = 2;
      vars.fast_restart_mode = true; // death restarts are "fast" for thresholds

      if (vars.Game_Type == 3)
      {
        // GT3: wait to RESUME (no reset), same-map allowed
        vars.ee_wait_for_resume = true;
        vars.ee_require_map_change = false;
      }
      else
      {
        // GT1/GT2: wait to RESET (then start from 0 on threshold)
        vars.gt12_wait_restart = true;
      }

      vars.pauseHold = 0;
      vars.unpauseHold = 0;
      vars.deathStableTicks = 0;
    }
  }

  // --- Detect explicit pause-menu action (game_paused: 1 -> 2) ---
  // Occurs on both "Restart Level" (fast restart) and "Quit".
  if (vars.timer_started
      && old.game_paused == 1
      && current.game_paused == 2)
  {
    vars.menu_action_armed = true;

    // Default to fast-restart behavior; if we later see menu_state==99 we reclassify to full-restart.
    vars.fast_restart_mode = true;

    if (vars.Game_Type == 3)
    {
      vars.ee_wait_for_resume = true;
      vars.ee_prev_map = current.selected_map;
      vars.ee_saw_map_change = false;
      vars.ee_saw_fresh_timer = false;
      vars.ee_require_map_change = false; // same map restart for fast path
    }
    else
    {
      // GT1/2: defer reset until we see fresh timer (fast path). Full-restart will override below.
      vars.gt12_wait_restart = true;
    }
  }

  // --- Reclassify to FULL RESTART if we reach main menu after pause-menu action ---
  // This distinguishes Quit-to-menu + new map from a same-map fast restart.
  if (vars.menu_action_armed
      && current.menu_state == 99)
  {
    vars.full_restart_path = true;

    // Full restart => use NORMAL thresholds on the next start.
    vars.fast_restart_mode = false;

    if (vars.Game_Type != 3)
    {
      // For GT1/GT2, queue a reset immediately once we leave gameplay for menu.
      vars.timer_started = false;
      vars.hasStoppedOnce = true;
      vars.pendingReset = true;
      vars.gt12_wait_restart = false;
      vars.pauseHold = 0;
      vars.unpauseHold = 0;
      vars.freshGameConfirmTicks = 0;

      // Clear GT1 split memory on full-restart path
      if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();
    }
    else
    {
      // GT3 stays paused and waits for a proper resume after map load.
      vars.ee_wait_for_resume = true;
      vars.ee_require_map_change = true; // new map is expected on full restart
      vars.ee_saw_map_change = false;
      vars.ee_saw_fresh_timer = false;
    }
  }

  // --- Flag fast-restart when leaving gameplay while already paused (legacy support) ---
  if (vars.timer_started
      && old.menu_state == 0
      && current.menu_state != 0
      && vars.is_paused
      && !vars.full_restart_path) // don't interfere once full restart is confirmed
  {
    vars.fast_restart_mode = true;
    if (vars.Game_Type == 3)
    {
      vars.ee_wait_for_resume = true;
      vars.ee_prev_map = current.selected_map;
      vars.ee_saw_map_change = false;
      vars.ee_saw_fresh_timer = false;
      vars.ee_require_map_change = false; // same map restart
    }
    else
    {
      vars.gt12_wait_restart = true; // defer reset until confirmed restart gates
    }
  }

  // --- Alive stability clears legacy block ---
  if (vars.AliveVals.Contains(current.dead)) vars.aliveStableTicks++;
  else vars.aliveStableTicks = 0;

  if (vars.blockStartUntilAlive
      && vars.aliveStableTicks >= vars.AliveConfirmTicks)
    vars.blockStartUntilAlive = false;

  // --- GT3: force pause on menu to avoid flicker; do not reset ---
  if (vars.Game_Type == 3
      && vars.timer_started
      && current.menu_state != 0
      && !vars.is_paused)
  {
    vars.timerModel.Pause();
    vars.is_paused = true;
  }

  // --- Pause/unpause debounce (only while in gameplay to avoid menu flicker) ---
  if (vars.timer_started && current.menu_state == 0)
  {
    bool p = current.game_paused > 0;
    vars.pauseHold = p ? vars.pauseHold + 1 : 0;
    vars.unpauseHold = p ? 0 : vars.unpauseHold + 1;

    bool blockUnpause =
      (vars.Game_Type == 3 && (vars.ee_wait_for_resume || vars.manualSplitHold > 0))
      || (vars.Game_Type != 3 && vars.gt12_wait_restart);

    if (!vars.is_paused && vars.pauseHold >= vars.PauseConfirmTicks)
    {
      vars.timerModel.Pause();
      vars.is_paused = true;
    }
    else if (vars.is_paused
             && !blockUnpause
             && vars.unpauseHold >= vars.UnpauseConfirmTicks)
    {
      vars.timerModel.Pause();
      vars.is_paused = false;
    }
  }

  // --- Non-GT3: menu exit / rollback / queued reset flow ---
  if (vars.Game_Type != 3)
  {
    // If exiting gameplay unpaused, behave like legacy menu exit (queue reset immediately).
    if (vars.timer_started
        && current.menu_state != 0
        && !vars.is_paused
        && !vars.full_restart_path)
    {
      vars.timer_started = false;
      vars.hasStoppedOnce = true;
      vars.pendingReset = true;
      vars.pauseHold = 0;
      vars.unpauseHold = 0;

      // Clear GT1 split memory on menu exit -> reset path
      if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();
    }

    if (current.menu_state == 0 && current.timer < old.timer)
    {
      // Hard map restart safeguard
      vars.timerModel.Reset();
      vars.timer_started = false;
      vars.is_paused = false;
      vars.hasStoppedOnce = true;
      vars.did_reset = true;
      vars.pauseHold = 0;
      vars.unpauseHold = 0;
      vars.freshGameConfirmTicks = 0;

      // Clear GT1 split memory on hard restart
      if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();
    }

    // Fresh-timer detection in gameplay (not used during full menu path).
    if (!vars.timer_started
        && vars.hasStoppedOnce
        && !vars.pendingReset
        && !vars.did_reset
        && current.menu_state == 0
        && current.timer <= vars.T_RESET_SMALL)
    {
      vars.freshGameConfirmTicks++;
      if (vars.freshGameConfirmTicks >= vars.T_RESET_CONFIRM_TICKS)
      {
        vars.pendingReset = true;
        vars.hasStoppedOnce = false;
        vars.freshGameConfirmTicks = 0;
      }
    }
    else if (current.timer > vars.T_RESET_SMALL
             || current.menu_state != 0
             || vars.pendingReset
             || vars.did_reset)
    {
      if (!vars.timer_started) vars.freshGameConfirmTicks = 0;
    }
  }

  // --- GT3: strict resume gates (map change only required after manual split / full restart) ---
  if (vars.Game_Type == 3 && vars.ee_wait_for_resume)
  {
    bool mapChanged = (current.selected_map != vars.ee_prev_map);
    if (!vars.ee_saw_map_change && mapChanged) vars.ee_saw_map_change = true;

    if (!vars.ee_saw_fresh_timer)
    {
      int lim = vars.T_RESET_SMALL + vars.T_FAST_FRESH_PAD;
      bool ok = vars.ee_require_map_change ? vars.ee_saw_map_change : true;
      if (ok && current.timer <= lim) vars.ee_saw_fresh_timer = true;
    }

    var dict = vars.fast_restart_mode ? vars.fast_start_times : vars.start_times;

    int thr2 = dict.ContainsKey(current.selected_map)
      ? dict[current.selected_map]
      : -1;

    bool mapReq = vars.ee_require_map_change ? vars.ee_saw_map_change : true;

    bool canResume =
      mapReq
      && vars.ee_saw_fresh_timer
      && current.menu_state == 0
      && vars.AliveVals.Contains(current.dead)
      && current.timer > old.timer
      && (thr2 >= 0 && current.timer >= thr2);

    if (canResume)
    {
      if (vars.is_paused) { vars.timerModel.Pause(); vars.is_paused = false; }
      vars.ee_wait_for_resume = false;
      vars.timer_started = true;
      vars.pauseHold = 0;
      vars.unpauseHold = 0;

      // Clear path flags on resume
      vars.fast_restart_mode = false;
      vars.menu_action_armed = false;
      vars.full_restart_path = false;

      // Clear GT1 split memory when GT3 resumes (paranoia no-op for GT1)
      if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();
    }
  }

  // --- GT1/GT2: fast path reset (same-map) then allow start{} using fast thresholds ---
  if (vars.Game_Type != 3 && vars.gt12_wait_restart && !vars.full_restart_path)
  {
    if (!vars.ee_saw_fresh_timer)
    {
      int lim = vars.T_RESET_SMALL + vars.T_FAST_FRESH_PAD;
      if (current.timer <= lim) vars.ee_saw_fresh_timer = true;
    }

    bool canResetThenStart =
      vars.ee_saw_fresh_timer
      && current.menu_state == 0
      && vars.AliveVals.Contains(current.dead)
      && current.timer > old.timer;

    if (canResetThenStart)
    {
      vars.timerModel.Reset();
      vars.timer_started = false;
      vars.is_paused = false;
      vars.did_reset = true;
      vars.gt12_wait_restart = false;
      vars.pauseHold = 0;
      vars.unpauseHold = 0;

      // Clear GT1 split memory on fast restart reset
      if (vars.gt1_split_done.Count > 0) vars.gt1_split_done.Clear();

      // fast_restart_mode stays true so start{} uses fast thresholds; start{} clears it.
    }
  }

  return true;
}