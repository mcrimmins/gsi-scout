# Notes from the NFDRS4 reference implementation

Findings from reading the US Forest Service's own reference code for the
GSI-based live fuel moisture model -- [`firelab/NFDRS4`](https://github.com/firelab/NFDRS4)
on GitHub, C++, authored by W. Matt Jolly (USFS, RMRS Fire Sciences
Laboratory) -- and comparing it against `R/gsi.R` and
`docs/live-fuel-moisture.md`. This is the actual code behind the 2024 paper
already cited there, not just another description of the method, so it's a
stronger check than the paper's own prose.

**Status: research only, nothing here has been implemented.** Logged
2026-09-15 per Mike's request, to revisit and decide what (if anything) to
change. See each item's "Action" line below.

Relevant files read in the NFDRS4 repo: `lib/NFDRS4/include/livefuelmoisture.h`,
`lib/NFDRS4/src/livefuelmoisture.cpp` (the `LiveFuelMoisture` class -- the
direct analog of `R/gsi.R`), and `lib/NFDRS4/src/nfdrs4.cpp` (the top-level
`NFDRS4` class, specifically its `Cure()` method and the "Herbaceous Load
Transfers" section that calls it).

## Confirmed: the LFM ramp formula matches

NFDRS4's `CalcRunningAvgHerbFM()` computes moisture as
`m_Slope * rescale + m_Intercept`, where `m_Slope = (Max-Min)/(1-GU)` and
`rescale` is GSI divided by GSImax, clamped to [0,1]. That's algebraically
identical to `gsi_to_lfm()`'s current piecewise form
(`Min + (Max-Min)*(GSI'-GU)/(1-GU)` for `GSI' >= GU`). Independent
confirmation that the GU-threshold fix already in `R/gsi.R` is correct, not
just paper-consistent.

**Action: none needed** -- this one already matches.

## Discrepancy: smoothing window (21 days vs. 28)

NFDRS4's actual default is `SetMAPeriod(MAPeriod = 21)` -- a 21-day trailing
running mean, not the 28 days the Jolly et al. (2024) paper states and
`R/gsi.R` currently defaults to. This matches what the NWCG training
material (already source #5 in `docs/live-fuel-moisture.md`) says; the
paper and the reference code disagree with each other here, and gsi-scout
picked the paper's number.

**Action:** decide whether to change `R/gsi.R`'s default smoothing window
from 28 to 21 days, or leave as-is and just note the discrepancy in the
docs. If changed, update the "window" default, its `helpText`, and add
NFDRS4 as a citation for the 21-day value in `docs/live-fuel-moisture.md`.

## Discrepancy: green-up threshold default (0.5 vs. 0.2)

NFDRS4's actual default is `SetLFMParameters(..., GreenupThreshold = 0.5, ...)`
for *both* herb and woody -- not the 0.2 the 2024 paper's Table 6 states.
0.5 is the value already listed as the NWCG-sourced alternative in the
worked-example table in `docs/live-fuel-moisture.md`; it's not a new
number, but it's now clear it's the reference code's own default, while
gsi-scout's sliders currently default to 0.2 (the paper's claimed value).

**Action:** decide whether `gu_herb`/`gu_woody` in `scout_defaults()` should
default to 0.5 instead of 0.2, and update the worked-example table's
framing in `docs/live-fuel-moisture.md` (it already shows all three GU
values, but currently presents 0.2 as the seeded default rather than 0.5).

## New context: real-time precipitation is a first-class GSI term

NFDRS4 multiplies a precip indicator directly into the core GSI product --
`GSI = tMinInd * vpdInd * daylenInd * prcpInd` -- rather than treating it as
a bolt-on the way the Daham (2018) citation in gsi-scout's comments frames
it. Its default window is 30 days (close to gsi-scout's 28) and its
threshold values are 0.5-1.5, units unconfirmed in the code or README (no
inches/mm label found anywhere) -- most likely inches given NFDRS
convention, but not verified. One thing that does match: precip is **off**
by default in NFDRS4 (`UseRTPrecip = false`), same as gsi-scout's toggle.

**Action:** low priority -- the on/off default and general shape already
match. Worth confirming precip units before citing NFDRS4's 0.5/1.5
thresholds anywhere, and maybe rewording the Daham (2018) framing to note
NFDRS4 treats it as a direct multiplicative term.

## New: herbaceous "curing ratchet" (not in gsi-scout)

NFDRS4 has a one-way lock for *annual* herbaceous fuel that gsi-scout's
model doesn't have at all. Once an annual herb's moisture has exceeded
120% in a year and then drops back below 120%, `canIncreaseHerb` latches
false for the rest of that year -- moisture is capped at whatever it last
reached (`ret = min(ret, lastHerbFM)`), regardless of what the GSI math
would otherwise predict, until an explicit `ResetHerbState()`. (Woody fuel
has no such ratchet -- fully reversible, like gsi-scout's current gate
logic for both fuel types.)

This directly conflicts with the reversibility gsi-scout's README describes
as a deliberate design choice ("drought can push a site back to dormancy at
any point," no "explicit multiple-seasons switch" needed) -- so this is
flagged as an intentional design difference to be aware of, not a bug to
fix reflexively. Practical effect: gsi-scout can currently show an annual
grassland re-greening mid-summer after a monsoon pulse, which the real
NFDRS4 reference implementation structurally cannot do once that grass has
already cured past 120% and dropped below it once that year.

**Action:** decide whether GSI Scout should adopt an equivalent one-way
ratchet for annual herbaceous fuel (as an optional toggle, most likely,
given it cuts against the app's stated design philosophy), or keep the
fully-reversible model as-is and just document the divergence from NFDRS4
in `docs/live-fuel-moisture.md`.

## New: the herb-to-dead-fuel curing formula is different, not just re-derived

This is the biggest finding. `docs/live-fuel-moisture.md` step 4 currently
describes the transfer of herbaceous fuel into the 1-hour dead fuel class
as a Scott & Burgan (2005) curve applied to the *resulting LFM percentage*:

$$\text{share transferred to dead} = \mathrm{clamp}\!\left(\dfrac{120 - LHFM}{120 - 30},\ 0,\ 1\right)$$

NFDRS4's actual `Cure()` function does not do this. It computes the cured
fraction directly from relative GSI and GU, with no reference to the
120%/30% moisture thresholds at all:

```cpp
double NFDRS4::Cure(double fGSI, double fGreenupThreshold, double fGSIMax)
{
   (m_GSI < fGreenupThreshold)? fctCur = 1
     : fctCur = -1.0/(1.0 - fGreenupThreshold) * (m_GSI/fGSIMax)
                + 1.0/(1.0 - fGreenupThreshold);
   if (fctCur < 0) fctCur = 0.0;
   if (fctCur > 1) fctCur = 1.0;
   // fctCur is the fraction of herbaceous fuel load transferred to the
   // 1-hr dead class; W1P = W1 + WHERB*fctCur, WHERBP = WHERB*(1-fctCur)
   return fctCur;
}
```

Simplified, with `GSI' = GSI/GSImax`:

$$\text{share transferred to dead} = \mathrm{clamp}\!\left(\dfrac{1 - GSI'}{1 - GU},\ 0,\ 1\right)$$

The two formulas agree at one endpoint only: at `GSI' = GU`, both say 100%
cured. Everywhere else they diverge substantially. Worked example at
GU = 0.5, GSI' = 0.75 (halfway between GU and fully green):

- NFDRS4's formula: `(1 - 0.75)/(1 - 0.5) = 0.5` -- 50% of the herb load
  still counted as cured.
- gsi-scout's current formula (run GSI' through the LFM ramp to get
  LHFM = 140%, then through the 120/30 curve): `clamp((120-140)/90, 0, 1)
  = 0` -- already fully green, 0% cured.

gsi-scout's curve (as currently implemented) reaches 0% cured about 40% of
the way from GU to `GSI' = 1`, then stays at 0% for the rest of the range.
NFDRS4's curing fraction declines gradually all the way to `GSI' = 1`. So
the Scott & Burgan (2005) citation describes a real, published curing
method, but it is not what NFDRS4's reference code actually runs --
NFDRS4 uses its own simpler, more direct GSI-based ramp instead, and never
references the 120%/30% LFM percentages in this calculation at all.

**Action:** decide whether `herb_load_transfer()` in `R/gsi.R` should be
rewritten to match NFDRS4's direct `(1-GSI')/(1-GU)` formula (dropping the
Scott & Burgan 120/30 dependency and its citation for this specific step),
or kept as-is with the divergence documented. If rewritten,
`docs/live-fuel-moisture.md` step 4 and its Sources list need updating to
cite NFDRS4 / the underlying `NFDRS4::Cure()` logic instead of (or
alongside) Scott & Burgan (2005), and Scott & Burgan would need to be
re-framed as "the published curing method GSI Scout doesn't currently use"
rather than the model's basis.

## Not yet checked

- `lib/NFDRS4/src/deadfuelmoisture.cpp`/`.h` -- dead fuel moisture, not
  examined; gsi-scout doesn't model dead fuels currently, so likely
  out of scope unless that changes.
- The `docs/_build/` Doxygen output in the NFDRS4 repo -- narrative
  documentation that might confirm the precip-threshold units.
