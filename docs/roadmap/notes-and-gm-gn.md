# Notes and the gm / gn routine

Plans only. Notes themselves are built (ADR 0014, 0.6.0); the routine below is not.

## Asked for (2026-10-13)

"a toggle mode to add a couple quick things that i can toggle visibility on separate from the
alerts … checkbox todos … with markdown … to link to things or text reminders" (built as
Notes), and "a gm / gn thing that will save stuff or go through new things we need to do and
prioritize for morning and night".

## Agreed shape

The app keeps the routine on time; an agent does the thinking.

1. **App, no AI.** A gm time and a gn time in Settings (the work schedule already exists).
   At each, one quiet `info`-style card on the Mac: "Good morning: 4 carried over, 7 new since
   last night", linking to the Notes view. It never takes focus.
2. **gn rollover, in the app.** Ticked lines move to a dated `## Done` log (pruned after N
   days); unticked ones gather under `## Tomorrow`. The Edit window offers a quick "anything
   for tomorrow?".
3. **gm with an agent.** A `/gm` skill command (and `needs-you gm`) reads the open items, the
   notes' `## Tomorrow` and `## Inbox`, and the GitHub/Linear/Jira pollers' items, writes a
   prioritised `## Today` (top 3, then the rest, each with its link) and posts one card when
   it's ready.

## Open decisions

- **How the gm agent reads.** Senders can't read items or notes. Options: run it with a reader
  token (simple, broad), or a narrow new read scope for the digest (stricter; the default per
  the security rule). Needs its own ADR.
- Where the rollover runs when the Mac sleeps at gn time (catch up at wake, or a server hub
  does it).
