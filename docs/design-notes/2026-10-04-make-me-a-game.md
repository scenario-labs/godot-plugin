# Make me a game

Status: open question (2026-10-04). No option chosen yet.

## The question

Can the plugin handle a request like "make me a game about a fox delivering mail in the rain"?

The steps in [Steps on any asset](2026-10-04-steps-on-any-asset.md) make and assemble assets, up to a playable character. A game also needs rules: what happens on a jump, scoring, losing, menus, levels. Something has to supply those rules.

## Options

| Option | How it works | Strengths | Limits |
|---|---|---|---|
| A. Game kits | Start from an MIT template game. Scenario LLM picks the kit that fits the request and lists its asset slots; the steps fill every slot (player, enemies, props, tiles, sky, UI, music, sound effects) in one style. | Playable result with no generated code; priced before anything runs; predictable | The game plays like its template |
| B. A coding agent drives the plugin | A coding agent writes the rules; the plugin's steps make and place the assets, under the same spending rules | Any kind of game | Needs a coding agent next to the editor |
| C. Built-in code writer | Scenario LLM writes GDScript; the plugin runs it headless, reads the errors and fixes them in a loop (1.25 to 2.5 CU per turn) | Everything stays inside the editor | The largest build by far; the quality of generated code is hard to guarantee |

A and B can coexist. "Make me a game" would pick a kit when one fits the request, and point to B when none does.

## Template candidates for A

These templates are under the MIT licence, checked on GitHub on 2026-10-04:

- Godot's official demo projects (`godotengine/godot-demo-projects`), including "Dodge the Creeps", the 2D game from the Godot tutorial.
- Kenney's starter kits for Godot: 3D Platformer, FPS, City Builder, Racing, Match-3, Basic Scene.

## Rough prices, not measured yet

- **2D kit:** about 50 to 150 CU.
- **3D kit:** several hundred CU, mostly the 3D models (80 CU each with Rodin 2.5).

## Next check

The cheapest test of option A: reskin "Dodge the Creeps" with a generated 2D character, enemies, background, music and sound effects, then measure the price and the time.
