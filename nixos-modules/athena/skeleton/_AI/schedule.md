# Schedule

Cron-like entries Claude maintains. Dispatcher polls this file every minute.

## Format

One entry per line:
```
- <time-spec> | <kind> | <payload>
```

`time-spec`:
- `at <ISO-datetime>` — single fire (e.g. `at 2026-04-25 08:30`)
- `every day HH:MM`
- `every <weekday> HH:MM` (monday..sunday)
- `every HH:MM` — every N hours

`kind`:
- `notify` — dispatcher sends `payload` directly as a Telegram DM
- `prompt` — dispatcher invokes `claude --print -p "$(cat _AI/<payload>)"` and DMs the output

## Entries

<!-- Claude: add/remove lines here. Use `athena-schedule "- ..."` to append. Commit changes. -->

- every day 07:00 | prompt | prompts/daily-seed.md
- every day 21:00 | prompt | prompts/daily-review.md
- every monday 09:00 | prompt | prompts/weekly-review.md
