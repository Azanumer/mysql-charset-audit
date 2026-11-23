#!/usr/bin/env bash
# mysql-charset-audit — audit MySQL/MariaDB databases, tables and columns
# for legacy utf8 (3-byte) charsets and report what should be utf8mb4.
#
# Why: MySQL's `utf8` is really utf8mb3 — it cannot store emoji or many
# non-Latin scripts (4-byte characters fail with "Incorrect string value").
# WordPress has used utf8mb4 since 4.2, but tables created by old plugins,
# imports or manual CREATE TABLE statements often still sit on utf8.
#
# Usage:
#   charset-audit.sh [--database DB]... [--all] [--target utf8mb4]
#                    [--collation utf8mb4_unicode_ci] [--fix] [--apply]
#                    [--json] [--quiet] [--host H] [--user U] [--password P]
#
#   --database DB   audit one database (repeatable)
#   --all           audit every non-system database
#   --target        desired charset (default utf8mb4)
#   --collation     desired collation (default utf8mb4_unicode_ci)
#   --fix           print ALTER statements that would fix the mismatches
#   --apply         actually run the ALTER statements (requires --fix)
#   --json          machine-readable output
#   --quiet         print only the summary line (or JSON)
#
# Exit codes: 0 = everything matches target, 1 = mismatches found,
#             2 = error (connection, bad flags, failed ALTER).
#
# Credentials: ~/.my.cnf [client] section, or --host/--user/--password.
# --apply never runs without --fix, and every ALTER is printed before it runs.
#
# License: MIT

set -u
PROG="$(basename "$0")"

TARGET="utf8mb4"
COLLATION="utf8mb4_unicode_ci"
FIX=0
APPLY=0
JSON=0
QUIET=0
ALL=0
declare -a DATABASES=()
MYSQL_ARGS=()

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

log() { [ "$QUIET" -eq 0 ] && echo "$@" ; }
err() { echo "$PROG: $*" >&2 ; }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---- argument parsing ----------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --database) [ -n "${2:-}" ] || { err "--database needs a value"; exit 2; }
                    DATABASES+=("$2"); shift 2 ;;
        --all) ALL=1; shift ;;
        --target) [ -n "${2:-}" ] || { err "--target needs a value"; exit 2; }
                  TARGET="$2"; shift 2 ;;
        --collation) [ -n "${2:-}" ] || { err "--collation needs a value"; exit 2; }
                     COLLATION="$2"; shift 2 ;;
        --fix) FIX=1; shift ;;
        --apply) APPLY=1; FIX=1; shift ;;
        --json) JSON=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --host) [ -n "${2:-}" ] || { err "--host needs a value"; exit 2; }
                MYSQL_ARGS+=(--host="$2"); shift 2 ;;
        --user) [ -n "${2:-}" ] || { err "--user needs a value"; exit 2; }
                MYSQL_ARGS+=(--user="$2"); shift 2 ;;
        --password) [ -n "${2:-}" ] || { err "--password needs a value"; exit 2; }
                    MYSQL_ARGS+=(--password="$2"); shift 2 ;;
        -h|--help) usage 0 ;;
        *) err "unknown option: $1"; usage 2 ;;
    esac
done

if [ "$ALL" -eq 0 ] && [ "${#DATABASES[@]}" -eq 0 ]; then
    err "nothing to audit: pass --database DB or --all"
    usage 2
fi

# Identifiers are validated before they ever reach a query (no quoting tricks).
valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
valid_ident "$TARGET" || { err "invalid --target charset: $TARGET"; exit 2; }
[[ "$COLLATION" =~ ^[A-Za-z0-9_]+$ ]] || { err "invalid --collation: $COLLATION"; exit 2; }

mysql_q() {
    mysql "${MYSQL_ARGS[@]}" --batch --skip-column-names --raw -e "$1" 2>/tmp/charset-audit.err
    local rc=$?
    if [ $rc -ne 0 ]; then
        err "mysql failed: $(head -n 1 /tmp/charset-audit.err)"
        exit 2
    fi
}

# ---- resolve the database list -------------------------------------------
if [ "$ALL" -eq 1 ]; then
    mapfile -t DATABASES < <(mysql_q "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME;")
fi

for db in "${DATABASES[@]}"; do
    valid_ident "$db" || { err "invalid database name: $db"; exit 2; }
done

# ---- audit ----------------------------------------------------------------
# Mismatches are collected as "level|database|object|current|desired".
declare -a MISMATCHES=()
declare -a FIX_SQL=()
DB_COUNT=0
TABLE_COUNT=0
COLUMN_COUNT=0

for db in "${DATABASES[@]}"; do
    DB_COUNT=$((DB_COUNT + 1))

    # Database default charset/collation.
    read -r db_charset db_collation <<< "$(mysql_q "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${db}';")"
    if [ "$db_charset" != "$TARGET" ] || [ "$db_collation" != "$COLLATION" ]; then
        MISMATCHES+=("database|${db}||${db_charset}/${db_collation}|${TARGET}/${COLLATION}")
        FIX_SQL+=("ALTER DATABASE \`${db}\` CHARACTER SET ${TARGET} COLLATE ${COLLATION};")
    fi

    # Tables whose charset or collation differs from the target.
    while IFS=$'\t' read -r tbl tbl_charset tbl_collation; do
        [ -z "$tbl" ] && continue
        TABLE_COUNT=$((TABLE_COUNT + 1))
        if [ "$tbl_charset" != "$TARGET" ] || [ "$tbl_collation" != "$COLLATION" ]; then
            MISMATCHES+=("table|${db}|${tbl}|${tbl_charset}/${tbl_collation}|${TARGET}/${COLLATION}")
            FIX_SQL+=("ALTER TABLE \`${db}\`.\`${tbl}\` CONVERT TO CHARACTER SET ${TARGET} COLLATE ${COLLATION};")
        fi
    done < <(mysql_q "SELECT TABLE_NAME, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${db}' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME;" | while IFS=$'\t' read -r t c; do
        # TABLE_COLLATION is e.g. utf8_general_ci — charset is the part before '_'.
        printf '%s\t%s\t%s\n' "$t" "${c%%_*}" "$c"
    done)

    # Text columns whose charset/collation differs from the target.
    # (Numeric/date columns have no charset; they are not listed here.)
    while IFS=$'\t' read -r col col_charset col_collation; do
        [ -z "$col" ] && continue
        COLUMN_COUNT=$((COLUMN_COUNT + 1))
        if [ "$col_charset" != "$TARGET" ] || [ "$col_collation" != "$COLLATION" ]; then
            MISMATCHES+=("column|${db}|${col}|${col_charset}/${col_collation}|${TARGET}/${COLLATION}")
        fi
    done < <(mysql_q "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME), CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '${db}' AND CHARACTER_SET_NAME IS NOT NULL ORDER BY TABLE_NAME, ORDINAL_POSITION;")
done

MISMATCH_COUNT=${#MISMATCHES[@]}

# ---- output ---------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
    printf '{\n  "target": "%s",\n  "collation": "%s",\n  "databases_checked": %d,\n  "tables_checked": %d,\n  "columns_checked": %d,\n  "mismatches": %d,\n  "issues": [\n' \
        "$(json_escape "$TARGET")" "$(json_escape "$COLLATION")" "$DB_COUNT" "$TABLE_COUNT" "$COLUMN_COUNT" "$MISMATCH_COUNT"
    i=0
    for m in "${MISMATCHES[@]}"; do
        IFS='|' read -r level db obj current desired <<< "$m"
        [ "$i" -gt 0 ] && printf ',\n'
        printf '    {"level": "%s", "database": "%s", "object": "%s", "current": "%s", "desired": "%s"}' \
            "$(json_escape "$level")" "$(json_escape "$db")" "$(json_escape "$obj")" \
            "$(json_escape "$current")" "$(json_escape "$desired")"
        i=$((i + 1))
    done
    printf '\n  ]'
    if [ "$FIX" -eq 1 ] && [ "${#FIX_SQL[@]}" -gt 0 ]; then
        printf ',\n  "fix_sql": [\n'
        i=0
        for s in "${FIX_SQL[@]}"; do
            [ "$i" -gt 0 ] && printf ',\n'
            printf '    "%s"' "$(json_escape "$s")"
            i=$((i + 1))
        done
        printf '\n  ]\n'
    else
        printf '\n'
    fi
    printf '}\n'
else
    if [ "$MISMATCH_COUNT" -eq 0 ]; then
        log "OK: ${DB_COUNT} database(s), ${TABLE_COUNT} table(s), ${COLUMN_COUNT} column(s) — all ${TARGET}/${COLLATION}."
    else
        log "MISMATCH: ${MISMATCH_COUNT} object(s) are not ${TARGET}/${COLLATION} (checked ${DB_COUNT} database(s), ${TABLE_COUNT} table(s), ${COLUMN_COUNT} column(s)):"
        for m in "${MISMATCHES[@]}"; do
            IFS='|' read -r level db obj current desired <<< "$m"
            if [ -n "$obj" ]; then
                log "  ${level} ${db}.${obj}: ${current} (want ${desired})"
            else
                log "  ${level} ${db}: ${current} (want ${desired})"
            fi
        done
    fi

    if [ "$FIX" -eq 1 ] && [ "${#FIX_SQL[@]}" -gt 0 ]; then
        if [ "$APPLY" -eq 0 ]; then
            log ""
            log "Fix SQL (dry run — nothing was changed; re-run with --apply to execute):"
        fi
        for s in "${FIX_SQL[@]}"; do
            log "  ${s}"
        done
    fi
fi

# ---- apply ----------------------------------------------------------------
if [ "$APPLY" -eq 1 ] && [ "${#FIX_SQL[@]}" -gt 0 ]; then
    log ""
    log "Applying ${#FIX_SQL[@]} ALTER statement(s)..."
    failed=0
    for s in "${FIX_SQL[@]}"; do
        if ! mysql_q "$s" >/dev/null; then
            err "ALTER failed: ${s}"
            failed=1
        fi
    done
    if [ "$failed" -eq 1 ]; then
        exit 2
    fi
    log "All ALTER statements applied. Re-run without --apply to verify."
fi

[ "$MISMATCH_COUNT" -eq 0 ] && exit 0 || exit 1
