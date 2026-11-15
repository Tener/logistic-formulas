# Logistic Formulas

<img src="mods/logistic-formulas/thumbnail.png" alt="" width="96" align="right">

Each formula computes one logistic group from constants, other groups, logistic network contents and recipes, and keeps it up to date as they change. Chests, combinators, cargo landing pads and space platform hubs use that group like one set by hand. Requires Factorio 2.1 with Space Age.

```lisp
(def "mall"      {transport-belt 200 fast-inserter 50 pipe:rare 10})
(def "mall rare" (quality-up (group "mall") 2))
(def "missing"   (keep-positive (subtract (group "mall") (network "Main" storage))))
(def "line x4"   (round-to-stacks (multiply 4 (ingredients electronic-circuit 1k))))
(def "to orbit"  (import-from (set-max (group "mall") (multiply 2 (group "mall"))) nauvis))
```

The reference is in the game. Open the editor from the shortcut bar, the corner button or Ctrl+Shift+G (by default). Hovering a function there shows its syntax, parameters and an example, and the **?** beside it opens its Factoriopedia page. The **Logistic formulas** Factoriopedia tab also holds the guide (sheets and updates, the language, request settings, the editor, and patterns for malls and space platforms), and **Tips and tricks** has a short introduction.

## Development

Mod sources are in [mods/logistic-formulas](mods/logistic-formulas). [Local tests](docs/testing.md)
lists the test requirements and cases; [Releases](docs/releases.md) describes how to publish.

| Command | Purpose |
| --- | --- |
| `make test` | Run the headless test suite. |
| `make play` | Open a sandbox with sample formulas, a bot-fed factory, and an orbital platform testbed. |
| `make package` | Build `dist/logistic-formulas_<version>.zip`. |
| `make install` | Build and copy the zip into Factorio's mods directory. |

[tools/make-icons.py](tools/make-icons.py) draws the function, guide, shortcut and title bar icons, and scales the hand-made emblem [tools/mod-icon.png](tools/mod-icon.png) into the mod icon and `thumbnail.png`. It needs Pillow and macOS system fonts.
