# From GSI to live fuel moisture

Reference notes for `gsi_to_lfm()` and `herb_load_transfer()` in `R/gsi.R` --
what each step does, why, and the equation behind it, so the assumptions
behind the "GSI model" tab's live-fuel-moisture curves are visible rather
than buried in the code. (Previously a "Live fuel moisture" tab in the app
itself; moved here for reference, 2026-09-15.)

## 1. Rescaling GSI to a 0-1 scale

GSI itself has no fixed ceiling -- how high it runs depends on the site.
Before it can drive a moisture ramp, it's divided by "GSImax," a
site-calibration value (the sidebar's GSImax slider), so the result always
falls between 0 and 1 regardless of how high GSI happens to run at a given
location. This is what the app calls "relative GSI."

$$GSI'_f = \dfrac{GSI_f}{GSImax_f}$$

In the original method, GSImax is a site's own historical maximum GSI, fit
from years of data. GSI Scout instead treats it as a slider you set
directly -- a simplification worth knowing about if you're comparing
numbers against a site-calibrated model elsewhere.

## 2. The moisture ramp itself

Relative GSI is then mapped onto an actual moisture percentage, separately
for herbaceous fuels (grasses and forbs) and woody fuels (shrubs, small
stems). Below a "green-up threshold" (GU), moisture is held at its minimum
-- the site isn't considered green enough yet for the ramp to apply. At and
above GU, moisture rises in a straight line, reaching its maximum exactly
when relative GSI reaches 1.

$$
LFM_f = \begin{cases}
Min_f & GSI'_f < GU_f \\[4pt]
Min_f + (Max_f - Min_f)\cdot\dfrac{GSI'_f - GU_f}{1 - GU_f} & GSI'_f \ge GU_f
\end{cases}
$$

| Fuel | Min | Max |
|---|---|---|
| Herbaceous | 30% | 250% |
| Woody | 60% | 200% |

Those endpoints, and the green-up threshold itself, are all sliders in the
sidebar's "Phase & scaling" panel ("Live fuel moisture endpoints" and the
two GU sliders) -- nothing here is a fixed constant. GU is worth singling
out: FEMS's own operational table doesn't list one, so there's no single
"correct" default to seed it from. Three sources give three different
answers -- 0.2, 0.3, and 0.5 -- shown worked out below.

### Worked example: three GU values, same relative GSI

Holding relative GSI at exactly 0.5 and varying only GU (herbaceous
endpoints, 30-250%):

| GU | Source | Herbaceous moisture | Share treated as dead |
|---|---|---|---|
| 0.2 | Jolly et al. (2024) Table 6 | 112% | ~8% |
| 0.3 | FEMS operational default | 93% | ~30% |
| 0.5 | NWCG NFDRS2016 training material | 30% (at its minimum) | 100% |

Same weather, same relative GSI -- but whether that day reads as barely
greening up or already back at minimum moisture depends entirely on which
GU convention is seeded. ("Share treated as dead" is explained in step 4.)

## 3. A second, separate "hold at minimum" rule

Independent of GU, GSI Scout also pins moisture straight to its minimum on
any day its own green-up/dormant classifier (see the "GSI model" tab's
phase band) says the site is dormant. The two rules usually agree, but
they're not the same mechanism -- GU acts on the moisture ramp's shape,
while the phase gate acts on the model's own state classification. On a day
near the boundary they can disagree about exactly why moisture is at its
floor.

## 4. From moisture to "how much is already dead"

Live herbaceous fuel doesn't just get less flammable as it dries -- past a
point, fire behavior models treat part of it as if it had already died and
joined the fast-drying 1-hour dead fuel class. That transfer happens
gradually: fully green at 120% moisture and above, fully transferred at 30%
and below, straight line between.

$$\text{share transferred to dead} = \mathrm{clamp}\!\left(\dfrac{120 - LHFM}{120 - 30},\ 0,\ 1\right)$$

This step only applies to herbaceous fuel -- woody fuel doesn't cure the
same way and isn't transferred in this model.

## Sources

1. Jolly, W.M., Nemani, R. & Running, S.W. (2005). A generalized,
   bioclimatic index to predict foliar phenology in response to climate.
   *Global Change Biology* 11, 619-632. -- the original GSI sub-indices (see
   the app's "Sub-index ramps" tab).
2. Daham, A. et al. (2018). Predicting vegetation phenology in response to
   climate change in Iraq. *Journal of Water and Climate Change*. --
   extended GSI with a precipitation control.
3. Jolly, W.M., Freeborn, P.H., Bradshaw, L.S., Wallace, J. & Brittain, S.
   (2024). Modernizing the US National Fire Danger Rating System (version
   4): simplified fuel models and improved live and dead fuel moisture
   calculations. *Environmental Modelling & Software* 181, 106181. -- steps
   1 and 2 above (their Eq. 9 and Eq. 10), and the 30-250% / 60-200%
   endpoints.
4. Scott, J.H. & Burgan, R.E. (2005). *Standard fire behavior fuel models*.
   USDA Forest Service GTR RMRS-GTR-153. -- step 4, the herbaceous-to-dead
   transfer curve, attributed there to Burgan, R.E. (1979), *Estimating
   live fuel moisture for the 1978 National Fire-Danger Rating System*, GTR
   INT-226.
5. National Wildfire Coordinating Group, NFDRS2016 Live Fuel Moisture
   Changes training material -- the alternative GU = 0.5 convention in the
   worked example above.
