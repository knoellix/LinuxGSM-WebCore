# Subagent: LGSM Config & Games Meta

Readonly audit. Focus: `config_editor.pl`, `games_meta.*`, `games.pl`, `games_admin.cgi`, config UI in `manage.cgi`.

## Read first

- `.cursor/rules/lgsm-games-config.mdc`
- `.cursor/rules/security-isolation.mdc` (validate_config_target)

## Search patterns

```bash
# Never write _default.cfg
rg -n '_default\.cfg' src/

# Palworld / OptionSettings parsing
rg -n 'OptionSettings|read_game_config|parse_game_config' src/lib/config_editor.pl

# Hardcoded game config paths
rg -n 'serverfiles/.*\.(ini|cfg|properties)' src/ | rg -v 'resolve_game|get_game_config'

# games_meta encoding
rg -n 'open\(.*games_meta' src/

# init_game_config on steamcmd (forbidden)
rg -n 'init_game_config' src/manage.cgi -A5
```

## Check manually

- Config save: `validate_config_target($path)` before write
- Palworld: parse/write only `OptionSettings=(...)` content; form reads same parser
- INI byte-exact writes (`>:raw` / `write_file_exact`)
- `games_meta_local.json` override semantics (full `fields` replace)
- Filemin links: `edit_file.cgi?path=&file=` not `/?path=` to file
- FTP/ProFTPD: `ftpasswd` not direct AuthUserFile edits (if in scope)

## Output

Bullet list. `critical` = writes to `_default.cfg` or unvalidated path; `important` = parser drift (form empty but raw OK).
