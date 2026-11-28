# Native Climb v0.13 for OpenMW 0.51

A climbing mod with held-input ledge detection, shimmying, and W to pull up and mantle. Movement uses native OpenMW movement controls and temporary Levitate effects. Original ledge detection starts from the collision surface and uses its normal to orient the grab.

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
| Hold Space | Start ledge detection after 0.35 simulation seconds by default. Release Space to cancel pending scans. Hold Space alone to grab and hang. |
| Alt + Space | Jump with ledge detection bypassed. |
| A or D while hanging | Shimmy along the same lip. |
| W while hanging | Pull up. Keep W held to move forward onto the ledge. |
| W already held at the grab | Continue into a mantle when a landing route is found. |
| S or F8 during a climb | Release. |

If you stay hanging while W is held, you can shimmy to another spot or release and press W again to try a manual pull-up. If you release W during a pull-up, the forward move waits at the top until you hold W again.

Open **Options → Scripts → Native Climb** to adjust the detection delay, retry window, and camera. The first-person camera dip on mounting is enabled by default. Space and W/A/S/D are physical keys.

## First-person prone pose test

In this test branch, press **F10** on dry ground in first person. The test holds you still, pitches the actor down, and puts the camera about 24 units above your feet. Mouse look remains available. Press **F10** again or open a menu to end the test. This test uses the installed first-person rig and leaves the collider at standing size.

To test your own pose, import your active first-person skeleton in Blender with the [Morrowind Blender Plugin](https://blender-morrowind.readthedocs.io/en/latest/basics/importing.html). The default is `meshes/xbase_anim.1st.nif`. MO2's Data tab shows which mod supplies the file. Pose the bones in an Action with the armature object transform unchanged. At 30 FPS, key the same pose at frames 0 and 60. In the Action Editor's Morrowind panel, add text keys `ncproneidle: start` at frame 0 and `ncproneidle: stop` at frame 60. Export to a staging folder with **Export Animations** and **Extract Keyframe Data** enabled.

Install just the exported KF as `Animations/xbase_anim.1st/ncproneidle.kf` in a separate MO2 mod. If your base first-person model uses a different path, mirror that path under `Animations` and replace the `.nif` extension with a directory of the same stem. Enable **Use additional anim sources** under **Launcher → Settings → Visuals → Animations** and restart OpenMW. With the F10 test off, switch to first person, open the console and run:

```lua
luap
local a = require('openmw.animation'); print(a.hasGroup(require('openmw.self'), 'ncproneidle'))
require('openmw.animation').playQueued(require('openmw.self'), 'ncproneidle', {loops=0})
```

Close the console to see the two-second pose. If the group check prints `false`, check the KF folder against the active skeleton path and confirm the exported file contains both text keys and bone channels.

## Performance and testing

Ledge scans run after a held Space press. At default settings there are at most six scans per hold, each with a 60-ray ceiling. Pull-up checks use a separate 48-ray search budget for landing candidates. Shimmying and checking for support at the feet use local probes during the active climb. The detector does no idle scanning.

In offline box scenes, initial scans used 9 rays in open space, 15 for a crate viewed square-on or at 30°, and 15 for a projecting cornice with room to hang. Lua syntax, input transitions, camera cleanup, and collision decisions passed offline tests. The controls have been tested in game. Coverage across Morrowind meshes and performance on real scenes vary with geometry. The detector samples selected heights and directions, so thin ledges and irregular collision meshes are useful test cases.

With diagnostics enabled, search `openmw.log` for `[NativeClimb]`. F7 toggles scan logging, and F6 reports the current climb state. The log reports ray counts on successful grabs and missed scans.

The private prototype began as an experiment with [Simple Climbing by Captaingildog](https://www.nexusmods.com/morrowind/mods/61066). This version uses an independent detector and includes Native Climb's own spell records, controls, and camera code.
