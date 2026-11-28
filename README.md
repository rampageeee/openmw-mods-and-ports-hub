# OpenMW Mods

Lua mods and patches for playing Morrowind in OpenMW.

## Mods

| Mod | What it does |
| --- | --- |
| [The Art of Alchemy](mods/art-of-alchemy/README.md) | Brew, refine, and purify potions with placed apparatus. Discover ingredient effects, grind raw materials, and save recipes. |
| [Universal Container Sorter](mods/universal-container-sorter/README.md) | Deposit items by category or quickly stack items that match the contents of an open container. |

Add the folder for each mod you use as a separate OpenMW data directory and enable its script list. Each folder has its own installation instructions and credits.

## Prototypes

| Prototype | What it does |
| --- | --- |
| [Native Climb](prototypes/native-climb/README.md) | Test held-input ledge detection, shimmying, and continuous mantling in OpenMW 0.51. |
| [Ultimate Fishing](prototypes/ultimate-fishing/README.md) | Test casting, timed bites, and line tension in OpenMW 0.51.0 using the original mod's pole and fish records. |

## Patches

| Patch | What it changes |
| --- | --- |
| [AURA](patches/aura/README.md) | Reuses scan results and spaces out interior and door classification work. |
| [ErnGlider](patches/ernglider/README.txt) | Builds a five-file override that reduces idle work and spaces out collision checks. |
| [Lua NPC Schedule](patches/lua-npc-schedule/README.md) | Uses timers for schedule checks and reduces NPC travel updates. |
| [Mudcrab Island Ingredient Sorter](patches/mudcrab-island-sorter/README.md) | Adds an event-driven ingredient sorter to the island’s ingredient chest. |
| [Pay Taxes](patches/pay-taxes/README.md) | Moves recurring tax checks to an in-game midnight timer. |
| [Potion Thrower](patches/potion-thrower/README.md) | Ignores unrelated messages sent through OpenMW’s `ShowMessage` event. |
| [Talking Matters Remastered](patches/talking-matters/README.md) | Handles missing settings registrations and configuration during dialogue setup. |
| [Toxicology](patches/toxicology/README.md) | Caches NPC distribution work and reduces idle combat and maintenance checks. |

Read the [patch installation guide](patches/README.md) before applying a patch.
