# mysql-charset-audit

Audit MySQL/MariaDB databases, tables and columns for legacy `utf8` (3-byte) charsets and report what should be `utf8mb4`.

## Why

MySQL's `utf8` is really `utf8mb3` — it cannot store emoji or many non-Latin scripts, and inserts fail with `Incorrect string value`. WordPress has used `utf8mb4` since 4.2, but tables created by old plugins, imports or hand-written `CREATE TABLE` statements often still sit on `utf8`. This script finds them all in one pass.

## Usage

```bash
# Audit one database
./charset-audit.sh --database wordpress

# Audit every non-system database
./charset-audit.sh --all

# Show the ALTER statements that would fix everything (dry run — changes nothing)
./charset-audit.sh --database wordpress --fix

# Actually run the ALTER statements (prints them first)
./charset-audit.sh --database wordpress --fix --apply

# Machine-readable output for monitoring
./charset-audit.sh --all --json
```

## Options

| Flag | Meaning |
| --- | --- |
| `--database DB` | Audit one database (repeatable) |
| `--all` | Audit every non-system database |
| `--target utf8mb4` | Desired charset (default `utf8mb4`) |
| `--collation utf8mb4_unicode_ci` | Desired collation (default `utf8mb4_unicode_ci`) |
| `--fix` | Print the `ALTER` statements that would fix the mismatches |
| `--apply` | Run the `ALTER` statements (implies `--fix`) |
| `--json` | Machine-readable output |
| `--quiet` | Print only the summary line (or JSON) |
| `--host / --user / --password` | Connection overrides (default: `~/.my.cnf` `[client]` section) |

## Output

```
MISMATCH: 3 object(s) are not utf8mb4/utf8mb4_unicode_ci (checked 1 database(s), 12 table(s), 84 column(s)):
  database mysite: utf8/utf8_general_ci (want utf8mb4/utf8mb4_unicode_ci)
  table mysite.wp_old_plugin: utf8/utf8_general_ci (want utf8mb4/utf8mb4_unicode_ci)
  column mysite.wp_posts.post_content: utf8/utf8_general_ci (want utf8mb4/utf8mb4_unicode_ci)
```

Exit codes: **0** everything matches, **1** mismatches found, **2** error (connection, bad flags, failed `ALTER`).

## Notes

- Column-level mismatches are reported but have no individual fix SQL — the table-level `CONVERT TO CHARACTER SET` fixes the table and all its columns in one statement.
- `--apply` never runs without `--fix`, and every `ALTER` is printed before it executes.
- Database/table names are validated against `^[A-Za-z0-9_]+$` before they reach any query.

## Requirements

- `mysql` client
- MySQL 5.7+ / MariaDB 10.2+ (uses `information_schema`)

## License

MIT — see [LICENSE](LICENSE).
