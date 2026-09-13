<<<<<<< HEAD
# Harvest — setup and deploy

Two files. `schema.sql` builds the database, `index.html` is the whole app.

## 1. Create the Supabase project

1. Go to supabase.com, create a project, and wait for it to finish provisioning.
2. Open **SQL Editor**, paste the entire contents of `schema.sql`, and run it.
3. Before running, change the last block at the bottom — it creates your admin account:

   ```sql
   select 'Christian', 'evangelist', crypt('1234', gen_salt('bf')), true
   ```

   Change `'Christian'` to your name and `'1234'` to your real 4-digit PIN. After the
   first run, delete that block so it isn't sitting in your SQL history.

4. Go to **Project settings → API** and copy the **Project URL** and the **anon public** key.

## 2. Configure the app

Open `index.html`, find the CONFIG block near the top of the script, and paste both values in:

```js
const SUPABASE_URL  = "https://xxxxx.supabase.co";
const SUPABASE_ANON = "eyJhbGci...";
```

Open the file in a browser to test. You should see your name on the sign-in screen.

## 3. Deploy to Netlify

Drag the folder containing `index.html` onto the Netlify drop zone at app.netlify.com/drop.
That's the whole deploy. You get a URL you can send to the team — it works on any phone,
no install, no app store.

To update later, drag the folder again. To use your own domain, Netlify → Domain settings.

## How security actually works here

A PIN is not a password, so the design doesn't pretend otherwise.

**Contact names are the only genuinely private data**, and the `contacts` table has row level
security enabled with no policies at all — the browser cannot read it under any circumstance.
Names come back only through `my_contacts`, which verifies your PIN inside the database before
returning anything, and only ever returns your own rows.

Everything else — counts, points, event dates, member names — is readable by anyone holding the
anon key. That's deliberate: it's what lets the team board update in real time, and it's all
data your team already shares with each other. No contact name passes through those views.

**Every write** goes through a `SECURITY DEFINER` function that checks the PIN first. Nobody can
insert points for someone else, and the funnel rules are enforced in the database, not in the
browser — so no one can log an attendance without a baptism behind it even if they open devtools.

PINs are stored as bcrypt hashes. If someone forgets theirs, you reset it from the Admin tab.

## Things worth knowing

**Scoring.** Within a month a contact scores once, at the value of the highest stage they reached
that month. Valid then baptized in the same month is 500, not 550. A fruit who attends four
services scores 1,000, not 4,000. This falls out of a single `MAX` in `v_monthly_contact_points`,
so if you change the point ladder the rule still holds as long as later stages are worth more.

**The percentage denominator.** Progress percentage uses the arithmetic sum of target × points
(2,300 for an evangelist, 950 for a member). Because of highest-stage-only scoring, hitting every
target exactly can land slightly under 100% if the same person counts for two stages in one month.
Treat the percentage as a pace indicator, not a precise ceiling.

**Removing someone** deactivates them rather than deleting. Their history and contacts stay intact
so past months don't change. They just stop appearing on the sign-in screen and the board.

**Changing targets or point values** takes effect from the 1st of the current month. Months already
closed keep the numbers they were scored with — that's what the `effective_from` columns are for.

**Offline.** If a simple-preaching tap fails, it queues in the browser and retries when the
connection returns. A banner shows while anything is waiting. Contact events are not queued —
they need database validation, so they fail loudly rather than silently.

**Gone quiet.** On the Funnel screen, a fruit who hasn't attended in 35 days is flagged. That's the
number worth watching — it's the difference between a baptism and a disciple.

## Changing the definitions

Both wordings are in one place, the `DEFS` object at the top of the script. They appear in the
logging sheets. Change them there and they change everywhere.
=======
# Pentecost-Festival-2026
this is a web app to be used for our preaching festival
>>>>>>> aa134106abd5e32850aefd14597d73374114adfc
