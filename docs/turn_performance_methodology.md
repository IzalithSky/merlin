# Turn Performance Methodology — Merlin Flight Model

How to derive **instantaneous** and **sustained** turn **rate** (°/s) and **radius** (m)
from the merlin table-driven aero model (`plane_flight_model.gd`, preset `default.json`).

The model itself computes the *ingredients* (corner speed, sustainable AoA, thrust/drag
tables) but never assembles a turn rate or radius. This document defines that final step.

---

## 1. Inputs

### 1.1 Lookup tables (from preset)

| Table | Meaning | Independent var |
|---|---|---|
| `lift_coefficient_table` | C_L vs AoA | AoA (deg) |
| `drag_coefficient_table` | C_D vs AoA | AoA (deg) |
| `thrust_coefficient_table` | thrust scale (0–1) vs speed | speed (m/s) |
| `control_authority_coefficient_table` | pitch-torque scale vs speed | speed (m/s) |

All tables are evaluated by **linear interpolation**, clamped to the endpoint value
outside the tabulated range. Call this operator `samp(table, x)`.

### 1.2 Scalar parameters

| Symbol | Source | Default |
|---|---|---|
| `S` — reference area | preset `reference_area` | 12 m² |
| `T_max` — max thrust | preset `max_thrust` | 14000 N |
| `τ_base` — base control torque | preset `base_control_torque` | 32000 N·m |
| `k_pitch` — max pitch authority | preset `max_pitch` | 1.0 |
| `c_q` — extra quadratic drag | preset `extra_linear_drag_quadratic` | 0.16 |
| `a_lin` — pitch angular drag (linear) | model `extra_angular_drag_linear_coefficients.x` | 20000 |
| `a_quad` — pitch angular drag (quad) | model `extra_angular_drag_quadratic_coefficients.x` | 2500 |
| `m` — mass | `PlaneCharacter` export (scene `.tscn`) | 3000 kg |
| `gravity_scale` | `PlaneCharacter` export | 1.0 |
| `ρ` — air density | model constant | 1.225 kg/m³ |
| `g` — gravity | 9.81 m/s² | 9.81 |

> **Note:** `m` and `gravity_scale` are **not** in the preset — they live on the
> `PlaneCharacter` node in the scene. Every result below scales with mass, so they must
> be read from there.

### 1.3 Derived constants

```
W       = m · g · gravity_scale          # weight (N)
C_Lmax  = max(lift_coefficient_table)     # ≈ 1.6027
AoA*    = AoA at C_Lmax                    # ≈ 19.9°  (positive_max_lift_aoa_deg)
```

---

## 2. Core physics

### 2.1 Dynamic pressure and forces at speed V

```
q(V)      = ½ · ρ · V²
L(V, AoA) = q(V) · S · samp(lift_table, AoA)
D(V, AoA) = q(V) · S · samp(drag_table, AoA) + c_q · V²
T(V)      = T_max · samp(thrust_table, V)
```

### 2.2 Load factor

```
n = L / W
```

`n` is the number of g's of lift produced. A turn requires `n > cos γ`
(see §2.4); a level turn requires `n > 1`.

### 2.3 Turn rate and radius — general (climb/dive aware)

For a steady, coordinated turn at flightpath angle `γ` (climb positive),
using the 3-DOF point-mass equations with `γ̇ = 0`:

```
ω(V, n, γ) = g · √(n² − cos²γ) / (V · cos γ)      # heading rate, rad/s
R(V, n, γ) = V · cos γ / ω                          # horizontal radius, m
```

Convert rate to degrees: `ω_deg = ω · 180/π`.

**Level-turn special case (γ = 0):**

```
ω = g · √(n² − 1) / V
R = V² / (g · √(n² − 1))
```

The `−cos²γ` term is the lift "spent" holding the flightpath; the `/cos γ`
projects body motion onto the horizontal heading change.

### 2.4 Validity

The turn is only physical when `n > cos γ`. If `n ≤ cos γ`, the wing cannot
both hold the flightpath and turn — rate = 0, radius = ∞ (no solution).

---

## 3. Instantaneous turn (lift- and control-limited)

The *maximum-performance* turn the aircraft can momentarily pull, ignoring
energy loss. Limited by **stall** (C_Lmax) and by **pitch control authority**,
whichever binds first. Energy/thrust is irrelevant here.

### 3.1 Achievable load factor at speed V

**Lift limit:**
```
n_lift = q(V) · S · C_Lmax / W
```

**Control limit** — the highest `n` whose required pitch rate the control
system can still command. Required pitch rate to sustain the turn:
`r = n · g / V`. Available torque must cover the angular-drag opposing it:

```
available τ = τ_base · samp(control_table, V) · k_pitch
required  τ = a_lin · r + a_quad · r²
```

Solve `a_quad·r² + a_lin·r − available τ = 0` for the max sustainable rate:

```
r_max  = ( −a_lin + √(a_lin² + 4·a_quad·available τ) ) / (2·a_quad)
n_ctrl = r_max · V / g
```

**Achievable:**
```
n_inst(V) = min(n_lift, n_ctrl)
```

### 3.2 Corner speed

The speed where `n_lift` and `n_ctrl` cross — the highest speed the aircraft can
still hold C_Lmax. This is the existing `_calculate_corner_speed()` output.
Below it the turn is lift-limited; above it, control-limited.

Maximum instantaneous turn **rate** occurs at (or just below) corner speed.
Minimum instantaneous **radius** occurs near it as well, on a broad flat minimum.

### 3.3 Algorithm

```
for V in speed_range:
    n = n_inst(V)                         # §3.1
    if n > cos γ:
        ω   = g·√(n² − cos²γ)/(V·cos γ)
        rate[V]   = ω · 180/π
        radius[V] = V·cos γ / ω
max instantaneous rate   = max(rate)
min instantaneous radius = min(radius)
```

---

## 4. Sustained turn (thrust/energy-limited)

The hardest turn the aircraft can hold **without losing speed** (`dV/dt = 0`).
Limited by the drag budget the engine (plus gravity, in a dive) can pay for.

### 4.1 Drag budget

Force balance along the velocity vector, steady state:

```
T(V) − D − m·g·sin γ = 0
⇒  D_allowed(V, γ) = T(V) − W · sin γ
```

- **Level (γ = 0):** `D_allowed = T(V)`.
- **Dive (γ < 0):** `−W·sin γ > 0` → larger budget → tighter/faster turn.
- **Climb (γ > 0):** budget shrinks; may go to zero (no sustained turn possible).

### 4.2 Max sustainable load factor at speed V

Find the largest AoA (≤ AoA*) whose total drag fits the budget, then its lift:

```
best_CL = 0
for AoA in 0 .. AoA*:
    if q(V)·S·samp(drag_table, AoA) + c_q·V² ≤ D_allowed(V, γ):
        best_CL = samp(lift_table, AoA)
n_sus(V, γ) = q(V) · S · best_CL / W
```

(This mirrors the model's `_get_sustainable_aoa_limit` / sustain-force logic,
extended with the gravity term for non-level turns.)

### 4.3 Algorithm

```
for V in speed_range:
    n = n_sus(V, γ)                       # §4.2
    if n > cos γ:
        ω   = g·√(n² − cos²γ)/(V·cos γ)
        rate[V]   = ω · 180/π
        radius[V] = V·cos γ / ω
max sustained rate   = max(rate)          # the "best rate" speed
min sustained radius = min(radius)        # a slower speed than best rate
```

The sustained rate curve is a single hump: lift-limited on the left,
thrust-limited on the right. Peak rate and minimum radius occur at
**different speeds** — radius is minimized slower, because `R ∝ V²`.

---

## 5. Reference results (m = 3000 kg, gravity_scale = 1, level turn)

| Metric | Value | At speed |
|---|--:|--:|
| Corner speed | 133 m/s | — |
| Max instantaneous rate | 29.6 °/s | 133 m/s |
| Min instantaneous radius | 257 m | ~120–130 m/s |
| Max sustained rate | 12.8 °/s | 85 m/s |
| Min sustained radius | 307 m | 65 m/s |
| Best AoA (all cases) | 19.9° (C_Lmax 1.60) | — |
| Load factor at corner | 7.07 g | 133 m/s |

### 5.1 Flightpath angle sensitivity (sustained)

| Angle | Peak rate | Min radius |
|---|--:|--:|
| +30° climb | none (cannot sustain) | none |
| +15° climb | none | none |
| 0° level | 12.8 °/s | 307 m |
| −15° dive | 19.5 °/s | 250 m |
| −30° dive | 26.7 °/s | 195 m |

Instantaneous figures are essentially unchanged by `γ` (energy-independent;
only the small `cos²γ` kinematic term shifts them). Sustained figures change
strongly because gravity enters the drag budget.

---

## 6. Notes, assumptions, and limitations

- **Turn plane is horizontal**, banked. A turn in the vertical (looping) plane
  is not captured by the `n² − cos²γ` form; gravity there alternately helps and
  hurts around the loop.
- **No structural g-limit.** The model caps the instantaneous turn by lift
  (C_Lmax) and control authority only. If a max-g clamp is wanted (e.g. 9 g),
  add `n_inst = min(n_lift, n_ctrl, n_struct)`.
- **Steady-state only.** `dV/dt = 0` and `γ̇ = 0`. Transient (entry) dynamics
  and pitch-rate lag are not modeled here.
- **Thrust falls steeply with speed** in this preset's table, so the sustained
  curve's right-hand cliff is sharper than a real turbojet with a thrust plateau.
- **Mass dependence is first-order.** All rates scale roughly as 1/√(wing
  loading) near the lift limit; halving mass nearly doubles sustained capability.

---

## 7. Suggested implementation hook

A `get_turn_performance(gamma_deg := 0.0)` helper on the flight model can return,
in one pass over a speed sweep, the four scalars (max/ min of rate/radius for each
regime) plus the optimum speeds — recomputed live from the current preset and the
`PlaneCharacter` mass, so HUD and AI can read them instead of hardcoding.
