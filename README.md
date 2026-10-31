# Spendwise

A fast, private expense tracker for iPhone, built with SwiftUI. It reads a plain CSV file that your own Shortcut or automation writes to, and turns it into a clear view of today, this month and your full history.

No accounts, no servers, no analytics. Your data stays in a file you control.

<!-- Add screenshots here, for example:
<p align="center">
  <img src="docs/today.png" width="240">
  <img src="docs/month.png" width="240">
  <img src="docs/spends.png" width="240">
</p>
-->

## Features

**Today**
- Today's total as the first thing you see, with a live update (and a light haptic) when a new spend arrives
- How today compares with your 30-day daily average
- "Left today to stay on budget" when you set an overall monthly budget
- Last 7 days at a glance, and the full list of today's spends

**Month**
- Month total, comparison with the *same days* of last month, and a month-end projection
- Category, day, bank and history views, with tappable donut charts
- Per-category and overall budgets with progress bars
- Insights: daily average, biggest spend, busiest weekday, top merchants, detected subscriptions
- Custom month start day, so the month can follow your salary or credit-card cycle

**Spends**
- All history grouped by day, with search (merchant, card or amount) and category/bank filter chips
- Result count and total for any search or filter
- "Needs a category" inbox for spends the app couldn't classify

**Editing and control**
- Tap a spend to change its category, optionally for every spend from that merchant, with undo
- Swipe to exclude a spend from totals
- Optional merging of duplicate entries (same card, amount and merchant within 2 minutes)
- Hide transfers from totals

**Privacy**
- Everything stays on the device; the app makes no network requests
- Tap the total to mask amounts
- Optional cover in the app switcher and optional Face ID / passcode lock

**Export**
- Share a month as CSV (escaped per RFC 4180 and safe against spreadsheet formula injection) or as a text summary

## Performance

- File reading and parsing run on a background actor, so the UI thread stays free
- The file is only re-read when its modification date or size changes, and polling only runs while the app is open
- Parsing is incremental when the file is only appended to
- A cached copy of the CSV gives an instant first screen at launch
- Categories are computed once at parse time, not on every redraw

## Requirements

- iOS 17 or later
- Xcode 15 or later (Xcode 26 if you use an Icon Composer `.icon` file)

## Getting started

1. In Xcode, create a new **iOS App** project using SwiftUI.
2. Delete the generated `ContentView.swift` and the generated `@main` app file.
3. Add `SpendsApp.swift` from this repo to the project.
4. If you want to use the Face ID lock, add `NSFaceIDUsageDescription` to the target's Info tab, for example *"Unlock your spends"*.
5. Optional: add an image set named `AppLogo` to `Assets.xcassets` to show your logo in the Today tab, and set your app icon in the target's General tab.
6. Run on a device or simulator.

On first launch, tap **Try with sample data** to explore the app, or **Choose CSV file** to connect your own.

## CSV format

One spend per line:

```
2026-10-01 11:40, Source|Last4|Amount|Merchant
```

Example:

```
2026-10-01 11:40, HDFC Credit Card|4321|450.00|SWIGGY*ORD123
2026-10-01 13:05, AU Bank Credit Card|8890|1,299.50|AMAZON PAY INDIA
2026-10-02 09:15, SBI Account|1122|-299.00|REFUND JIO
```

- The date is `yyyy-MM-dd HH:mm` (24-hour, local time)
- Amounts may contain commas; negative amounts are treated as refunds and netted against totals
- Lines that can't be read are skipped and counted in the app, so you can spot format problems

## Connecting your data

Any tool that can append a line to a text file works. A common setup is an iOS Shortcut that runs when a bank or card SMS arrives, extracts the amount and merchant, and appends a line to `myspends.csv` in iCloud Drive or on your device. In the app, choose that file once; it is remembered and re-read automatically.

## Customising categories

Edit `Categorizer.rules` in `SpendsApp.swift`. Each rule is a category name and a list of keywords matched against the **merchant only**. Keywords of 5 characters or fewer match whole words (so `ola` doesn't match "Coca Cola"); longer keywords match word prefixes (so `pharm` matches "pharmacy"). To add a category, also add it to `Cats.all` with a colour and an SF Symbol.

You can also teach the app from inside it: change a spend's category and choose "Apply to all". These rules are stored on the device and listed in **Settings → Learned categories**.

## Project structure

Everything lives in one file for easy copying. It is organised in sections:

| Section | Purpose |
|---|---|
| Models, formatting, categoriser | Data types, Indian currency formatting, keyword matching |
| `Engine` (actor) | File access, incremental CSV parsing, disk cache |
| `Store` (`@Observable`) | App state, recomputing totals, settings, undo, Face ID |
| Views | Today, Month, Spends, Settings, detail/review/budget sheets |

## Known limitations

- Home Screen and Lock Screen widgets, and App Intents (Siri / Shortcuts), are not implemented yet
- No notes on individual spends
- Performance has been designed for typical personal use (tens of thousands of rows at most); very large files may need the work listed in the roadmap

## Roadmap

- Widgets for today's total and budget left (needs an App Group)
- App Intents to add a spend or read today's total
- Manual add for cash spends
- File-presenter based change detection instead of polling
- Unit tests for the parser and categoriser

## Privacy

Spends does not collect, transmit or store your data anywhere except on your device and in the CSV file you choose. Please don't commit your real spending data to a public repository.

## License

Choose a license before publishing, for example MIT, and add a `LICENSE` file.
