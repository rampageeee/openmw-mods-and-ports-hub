# Native Climb v0.12 for OpenMW 0.51

A climbing prototype with held-input ledge detection, shimmying, and an optional continuous mantle. Movement uses native OpenMW movement controls and temporary Levitate effects. Original ledge detection starts from the collision surface and uses its normal to orient the grab.

## Install

1. Install this folder as an OpenMW data directory or a separate MO2 mod. Its root contains `NativeClimb.esp`.
2. Enable both entries in OpenMW. If you use MO2, check the exported `openmw.cfg`.

   ```ini
   content=NativeClimb.esp
   content=NativeClimb.omwscripts
   ```

3. When upgrading from a private Native Climb build, replace it and use a save made while standing normally. If another climbing mod handles the same inputs, disable its scripts while comparing the two.

## Controls

| Input | Action |
| --- | --- |
| Tap Space | Jump normally. |
| Hold Space | Start ledge detection after 0.35 simulation seconds by default. Release Space to cancel pending scans. |
| Alt + Space | Jump with ledge detection bypassed. |
| A or D while hanging | Shimmy along the same lip. |
| Fresh Space press while hanging | Pull up. |
| W at the top | Move forward onto the ledge. |
| S or F8 during a climb | Release. |

Open **Options → Scripts → Native Climb** to adjust the detection delay, retry window, and camera. Enable **Continuous mantle** to pull up automatically when W is held at the grip and a landing route is found. Keep W held to move over the lip. The first-person camera dip on mounting is enabled by default. Space and W/A/S/D are physical keys.

## Performance and testing

Ledge scans run after a held Space press. At default settings there are at most six scans per hold, each with a 60-ray ceiling. Pull-up checks use a separate 48-ray search budget for landing candidates. Shimmying and checking for support at the feet use local probes during the active climb. The detector does no idle scanning.

In offline box scenes, initial scans used 9 rays in open space, 15 for a crate viewed square-on or at 30°, and 15 for a projecting cornice with room to hang. Lua syntax, input transitions, camera cleanup, and collision decisions passed offline tests. Collision on Morrowind meshes and in-game timing still need testing. The detector samples selected heights and directions, so thin ledges and irregular collision meshes are useful test cases.

With diagnostics enabled, search `openmw.log` for `[NativeClimb]`. F7 toggles scan logging, and F6 reports the current climb state. The log reports ray counts on successful grabs and missed scans.

The private prototype began as an experiment with [Simple Climbing by Captaingildog](https://www.nexusmods.com/morrowind/mods/61066). This version uses an independent detector and includes Native Climb's own spell records, controls, and camera code.
