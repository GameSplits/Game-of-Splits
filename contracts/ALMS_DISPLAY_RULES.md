# Alms display rules for the site (/alms and the map sign)

No contract change; these are rules for reading FairLens / FairCore / AlmsVote correctly (v3.4 audit I-2, I-3; v3.5 audit frontend notes).

## Which chapter's pot to show

`FairLens.greenwood()` reads the chapter that `core.activeFair()` returns. Between chapters that is `(false, 0)`, so `greenwood()` falls back to Chapter 0's numbers. Don't show those.

- **A chapter is running** (`fairActive == true`): show `almsThisFair` for `fairId`.
- **Between chapters** (`fairActive == false`): show the next chapter's pot instead.
  - Let `n = core.fairCount() - 1` (the newest scheduled Chapter).
  - If `core.fairs(n).start > now`, the next chapter is `n`.
  - Otherwise no next chapter is scheduled yet; the next chapter is `n + 1`. Carries from a zero-vote Chapter land in `almsByFair(n + 1)` even before Chapter `n + 1` is created, so read it anyway.
  - Show `core.almsByFair(next)` and `core.almsCarriedIn(next)`.

## The "carried" label

`almsCarriedIn[f]` only ever goes up. After Chapter `f` pays out, `almsByFair(f)` drops to 0 but `almsCarriedIn(f)` keeps its old value.

- Show "includes N USDG carried from past chapters" **only** next to the pot of the running Chapter (or the next chapter, between chapters), and only when `N > 0`.
- Never show it on a past Chapter, and never as a share of a past chapter's current balance.
- On the running or next chapter, `almsCarriedIn ≤ almsByFair` always holds, so the label can't exceed the pot it sits under.

## A chapter being voted on

The vote can run after its Chapter ends (up to Chapter end + 14 days), so between chapters the live vote is usually on the chapter that **just ended**, while the pot rule above shows the next chapter's (often empty) pot. Show both.

- Check the newest chapters (`fairCount - 1` and `fairCount - 2` cover it, since only one Chapter can be scheduled ahead).
- A chapter is **"being voted"** when its windows are set and `suggestStart ≤ now < voteEnd` (label the phase: suggestions open before `voteStart`, voting from `voteStart`).
- After `voteEnd` and before `finalize`, show it as "vote closed, result pending". Once `Finalized` fires, show the winner, or "no votes: Alms carried to the next chapter".
- Show that chapter's own pot (`core.almsByFair(f)`) on its vote card, with its carried label if `almsCarriedIn(f) > 0`, since that is what the vote decides.

## Vote windows: always the current ones

Windows can be re-set before suggestions open, and cleared with `clearWindows` before the chapter starts (v3.5). Never cache the first announcement.

- Read `AlmsVote.windows(f)` live (it returns zeros after a clear), or follow the events with the **latest one winning**: `WindowsSet` replaces earlier windows, `WindowsCleared` removes them.
- After a clear, show "vote dates to be announced" until a new `WindowsSet`, and update any countdowns and calendar text.

## "Played this chapter" and vote eligibility

`FairLens.player(who).playedThisFair` uses `activeFair()`, so **between chapters it checks Chapter 0**. Don't use it for anything but a running Chapter.

- For whichever Chapter is on screen, call `core.playedIn(f, who)` directly.
- On a vote card, a wallet can suggest or vote only if `core.playedIn(f, who)` and `fairPass.heldSince(who)` is non-zero and earlier than `windows(f).suggestStart`, and it hasn't already (`hasSuggested(f, who)`, `voted(f, who)`). Show the reason when a wallet can't.

## Past chapters

For history, use events, not current balances: `AlmsReleased` / `AlmsCarried` (AlmsVote), `Finalized` for the winner, and `ReceiptPosted` for the donate.gg receipt and Safe tx hash.
