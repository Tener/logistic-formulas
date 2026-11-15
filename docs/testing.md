# Local tests

Run `make test` with Factorio 2.1.24 or later, Space Age and Python 3 installed. The runner uses
the macOS Steam installation by default; set `FACTORIO` to the executable's absolute
path for another installation. Only `reload-graphics` loads graphics; no screenshots are produced.

Each case runs in a fresh game process, and the suite returns nonzero if any fail.
Full logs are retained per case under `tmp/test-logs/`. Game configuration, saves
and runtime output are isolated under `.factorio-test/`.

| Test Case | Verifies |
| --- | --- |
| `sexp` | S-expression lexer/parser/printer, `k`/`M`/`G`, escaping, syntax errors |
| `formulas` | All functions, nesting, errors, source updates, quality research unlocks |
| `editor` | Tree widgets, live previews, step inspector, multi-line text editor |
| `docs` | Documented examples and guide snippets evaluate as shown; every reference text has its locale keys |
| `window` | Corner toggle, resizing, maximizing, pinning, persisted position/size |
| `network` | Network reads by name and surface/position, `storage`/`providers`/`all` scopes |
| `settings` | `max`, `import_from`, `request_from`, `min_delivery` propagation across all operators |
| `recipes` | Recipe ingredients, average probabilistic products, recipe chooser |
| `guard` | Group prefixes, chat warning & automatic undo of manual edits to owned groups |
| `sheets` | Multi-sheet tabs, prefix conflict rules, cross-sheet isolation |
| `save`, `reload`, `reload-graphics` | Persistence of sheets, prefixes, and formulas across save/load; loading with graphics |
| `playtest`, `demo-factory`, `demo-space` | End-to-end sandbox factory and orbital platform delivery scenarios |

The release tooling has its own tests:

```sh
python3 -m unittest discover -s tools -p test_release.py
```
