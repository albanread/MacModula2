# Cocoa demo test harness (Ptcl-driven, headless)

GUI demos block in `Cocoa.RunApp`, so they can't be observed by a normal headless
test. `library/macrtmod/DemoHarness.mod` lets a demo be driven from a tiny Tcl
script (via the embedded `Ptcl` interpreter) instead, and snapshot itself to a PNG
through the offscreen `Cocoa.Snapshot` path (no window server needed).

A demo enters script mode when launched with `-- --script <path>`; otherwise it
runs interactively. The driver forwards args after `--` into `ProgramArgs`.

```
newm2-driver run --library library cocoademos/<demo>.mod -- --script cocoademos/test/<demo>.tcl
```

## Verbs the harness registers

| Verb           | Effect                                                        |
|----------------|--------------------------------------------------------------|
| `step <n>`     | advance the demo's simulation n frames (calls its StepProc)  |
| `key <name>`   | deliver a key — a single char, or `left right up down space tab enter esc backspace …` (mapped by the demo's KeyProc) |
| `snap <path>`  | render the demo's NSView offscreen to a PNG                  |
| `get <name> [i]` | read a named integer the demo exposes via `DemoHarness.SetQuery` — lets a script branch, assert, or play adaptively, e.g. `if {[get gameover]} {…}`, `set h [get height $c]` |

…plus everything `Ptcl` already gives a script (`set` `puts` `expr` `if` `while` `proc` …).

A demo opts into `get` by calling `DemoHarness.SetQuery(MyState)` before `Drive`,
where `MyState(name, index): INTEGER` returns the value. Tetris exposes
`lines score level gameover flashing height<c>`.

## Scripts here

- `simd_particles.tcl` — evolve the swirl, snapshot, reseed (`key r`), snapshot.
- `worms.tcl` — let the coroutine AI hunt treats, steer the player, snapshot.
- `term_demo.tcl` — open the File menu, walk to View ▸ Toggle Help, type into the
  field, snapshot each state.
- `tetris.tcl` — stash a piece to HOLD, then hard-drop a run of pieces (the 7-bag
  gives the variety) and snapshot the stack. Tetris adds a `hold` key verb.
- `tetris_greedy.tcl` — shows the `get` verb: plays adaptively from `get height`
  feedback and branches on `get gameover`/`get flashing`.
- `asteroids.tcl` — spray-fire in a rotating sweep, then confirm rocks were hit via
  `get score`/`get asteroids`. Asteroids exposes score/wave/lives/asteroids/saucer/gameover.
- `asteroids_ufo.tcl` — spawn the saucer (`key saucer`) and let it shoot the central
  ship into debris; checks `get saucer`/`get lives`.
- `breakout.tcl` — `key space` to serve, step the physics, confirm bricks break via
  `get score`/`get bricks`. Breakout exposes score/level/lives/bricks/launched/gameover.
- `starturret.tcl` — bring a fighter in (`key enemy`), let its asterisk bolts hit the
  un-dodged central turret → flash + life loss. Exposes score/lives/enemies/flash/gameover.
- `synth.tcl` — play a sine then a saw note and snap the scope+spectrum (they differ by
  waveform since both render from real samples), then `key auto` to auto-play the ABC tune.
  Synth exposes wave/octave/auto/note/events.

Note: the `get` verb makes demo state assertable from a script, but it doesn't by
itself make every state reachable. Tetris's line-clear flash needs a *completed
row*, and a naive height-greedy buries holes (S/Z always notch flat ground), so
forcing a clear from a script would need a hole-avoiding placement AI. The flash +
line scoring are simple and confirmed wired; they're best seen by playing.

Each demo adds script mode in ~6 lines: a `DoSteps`/`DoKey` pair plus a
`DemoHarness.ScriptArg` / `DemoHarness.Drive` branch in its `main`.
