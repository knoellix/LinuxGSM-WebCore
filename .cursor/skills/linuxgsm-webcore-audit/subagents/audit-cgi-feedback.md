# Subagent: CGI & Success Feedback

Readonly audit. Focus: `src/*.cgi`, Lang files.

## Read first

- `.cursor/rules/no-blind-success-feedback.mdc`
- `.cursor/rules/webmin-cgi.mdc`
- `.cursor/rules/project-core.mdc`

## Search patterns

```bash
# Wrong lang placeholders (Webmin uses $1 not %s)
rg '%s' src/lang/

# Success via URL alone
rg -n '\?saved=1|\?ok=1|\?msg=' src/*.cgi

# redirect without exit on next lines
rg -n '&redirect\(' src/*.cgi -A1

# Blind truthiness on config flags
rg -n '\$in\{.*\}\s*\?' src/*.cgi | rg -v module_config_bool

# module_config save without or/ error
rg -n 'module_config_save|save_module_config' src/ -A2
```

## Check manually

- GET handlers: Flash consume before success banner?
- POST: read-back after write?
- Async actions → `job_live.cgi` not fake OK?
- Dynamic UI built in Perl; `text('key', $arg)` uses `$1` in lang file
- Both `de` and `en` keys for new strings

## Output

Bullet list. `critical` = blind success or missing escape on user input; `important` = missing flash/verify.
