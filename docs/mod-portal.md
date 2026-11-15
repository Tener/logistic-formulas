# Logistic Formulas

**Logistic groups computed by formulas.** Requires **Factorio 2.1** with **Space Age**.

Each formula computes one logistic group from constants, other groups, logistic network contents and recipes, and keeps it up to date as they change. Chests, combinators, cargo landing pads and space platform hubs use that group like one set by hand.

```lisp
(def "mall"      {transport-belt 200 fast-inserter 50 pipe:rare 10})
(def "mall rare" (quality-up (group "mall") 2))
(def "missing"   (keep-positive (subtract (group "mall") (network "Main" storage))))
(def "line x4"   (round-to-stacks (multiply 4 (ingredients electronic-circuit 1k))))
(def "to orbit"  (import-from (set-max (group "mall") (multiply 2 (group "mall"))) nauvis))
```

![The formula editor: each definition with its group's contents, its formula as a tree and as text, and a function's tooltip][editor]

## Getting started

Open the editor from the shortcut bar, the corner button or Ctrl+Shift+G (by default). Hovering a function there shows its syntax, parameters and an example, and the **?** beside it opens its Factoriopedia page.

The **Logistic formulas** Factoriopedia tab holds the full reference and a guide: sheets and updates, the language, request settings, the editor, and patterns for malls and space platforms. **Tips and tricks** has a short introduction.

[editor]: images/editor.png
