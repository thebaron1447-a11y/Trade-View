# Generators

The metadata, seed data and build log are generated, not hand-edited. These scripts were written in the assistant's
cloud workspace, so paths start with `/home/claude/` (`ROOT`, `OUT`, `BUILD`, `APEX` near the top of each file).
Point them at this project before running them anywhere else.

| Script | Writes |
|---|---|
| `gen_metadata.py` | Every object, field, layout, list view, tab, permission set, custom metadata type and credential under `force-app/main/default` |
| `gen_seed.py` | `data/*.json` seed records |
| `dump_fields.py` | `fields_live.json`: field definitions read back from the generated metadata |
| `build_doc.js` | `Trade_Import_Build_Log.docx` (needs `npm install docx`; reads `spec.json` and `fields_live.json`) |
| `../verify/gen_tests.py`, `gen_tests3b.py` | Vector test classes, after checking the vectors against the Python ports |
| `../verify/gen_samples3.py` | Sample dealer files and the expected flags |
| `../verify/gen_reset_full.py` | `scripts/apex/reset-reference-data.apex` |
