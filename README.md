# GroupWorth

A World of Warcraft Forever addon that shows the net worth of you and your group in a small movable window. Group members who also run GroupWorth share their numbers with each other automatically.

```
Player 1: 12g 50s (48g 10s)
Player 2: 3g 4s 5c (20g)
Party: 15g 54s 5c (68g 10s) / 100g
```

Each line shows **bag value** followed by **net worth** in parentheses:

- **Bag value**: your gold plus the vendor value of everything in your bags.
- **Net worth**: bag value plus the vendor value of your equipped gear, including the bags you have equipped (quivers and ammo pouches too).
- **Party line**: the same totals for everyone listed, and the group goal if one is set.

## Installation

1. Download a ZIP of this repo.
2. Extract and put the `GroupWorth` folder in your AddOns directory, for example `World of Warcraft\_classic_beta_\Interface\AddOns\`.
3. Restart the game, or type `/reload` if it's already running.

If the addon shows as out of date, enable "Load out of date AddOns" on the character select screen. You can also set the `## Interface:` line in `GroupWorth.toc` to the number printed by `/dump (select(4, GetBuildInfo()))`.

## Usage

The window is shown by default. Drag it with the left mouse button and it remembers its position.

| Command | What it does |
| --- | --- |
| `/gw` or `/groupworth` | Toggle the window |
| `/gw show`, `/gw hide` | Show or hide the window |
| `/gw reset` | Move the window back to the center of the screen |
| `/gw goal <amount>` | Set a group goal (group leader only) |
| `/gw goal clear` | Remove the goal (group leader only) |
| `/gw goal` | Print the current goal |

### Group goals

The group leader can set a target for the whole group, for example `/gw goal 10s` or `/gw goal 1g 50s`. The goal is sent to everyone running the addon, and the Party line turns green once the group's net worth reaches it.

Only the actual group leader can set a goal, and members ignore goal messages from anyone else. The goal is cleared when you leave the group.

## How it works

- Items are valued at their **vendor sell price**. Auction house prices aren't used. To use another price source such as Auctionator or TSM, change `GetItemValue()` in `GroupWorth.lua`.
- Values are recalculated shortly after your bags, gold or equipment change.
- Each client sends its two totals to the group over the addon message channel (party, raid or instance group), and re-sends them whenever the roster changes.
- Only people running GroupWorth appear in the list.

## Limitations

- The bank and the ammo slot are not counted.
- Items the client hasn't cached yet count as zero until their data loads, then the totals correct themselves.
