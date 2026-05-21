# Spec authoring patterns

Distilled from `.sui-prover-docs/guide/SKILL.md`, `.sui-prover-docs/guide/spec-reference.md`, and the working examples in `.sui-prover-docs/examples/`. Refer back to those for primary sources.

## 1. Visibility classification regex

`move_document_symbols` does **not** return visibility — every function comes back as `kind: 'function'`. The `specify` skill classifies visibility via comment-stripped regex over the `.move` source. The contract:

```js
// Group 1: leading visibility/qualifier tokens (trimmed)
// Group 2: function name
const FN_DECL = /^(?:\s*#\[[^\]]*\][^\n]*\n)*\s*((?:public(?:\(package\))?\s+)?(?:entry\s+)?(?:native\s+|macro\s+)?)fun\s+([A-Za-z_][A-Za-z0-9_]*)/gm;
```

Classification rules:

- `public(package)` → **excluded** (skill scope: external API only).
- `public` (no `(package)`) → included.
- `entry` (with or without `public`) → included.
- `native` `public` → included; native bodies are opaque but specs are still valid via `requires` / `ensures`.
- `macro` → excluded (compile-time, not runtime-callable).
- private `fun` (no visibility token) → excluded.

Attribute exclusion for `#[test_only]` / `#[test]`:

- The `FN_DECL` regex already consumes any leading `#[...]` attribute block via the `(?:\s*#\[[^\]]*\][^\n]*\n)*` prefix, so `match[0]` (the whole match) covers the attribute *and* the `fun NAME` declaration.
- **Implementation:** test `match[0]` itself for `/#\[\s*(?:test_only|test)\b/`. If it matches, exclude the function.
- **Do NOT** scan backward from `match.index` — that points to the start of the attribute block, not the `fun` keyword, so any look-behind from there picks up content that belongs to the *previous* function and produces false negatives on the function under inspection.
- **Do NOT** use a fixed character window (e.g. 200 chars). The naive form over-matches: a `#[test_only]` 3 lines earlier taints all subsequent functions in the file.

## 2. Canonical spec body shape

> The body shape below is the same whether the spec is inline or in a separate package. The **default layout wraps it in a separate spec package with `#[spec(prove, target = <fn>)]`** — see §3. The bare `#[spec(prove)]` form shown here is the `--inline` opt-out.

The minimal twin function pattern (from `.sui-prover-docs/guide/SKILL.md`):

```move
#[spec(prove)]
fun <name>_spec(<params>): <return_type> {
    requires(<precondition>);
    let __old = clone!(<mutable_ref>);     // only when capturing pre-state
    asserts(<abort_condition>);             // mirror each `assert!(cond, EError)` minus the error tag
    let <r> = <name>(<args>);
    ensures(<postcondition>);
    <r>
}
```

Imports live in a `#[spec_only]` block at the bottom of the file. **Always tag the import block `#[spec_only]`** so it gets stripped from production bytecode:

```move
#[spec_only]
use prover::prover::{requires, ensures, asserts, clone};
#[spec_only]
use prover::ghost::{declare_global, global};   // only when using ghost state
```

## 3. Spec layout — separate package is the default

**The default layout is a separate sibling spec package** — not inline specs in the production source. This matches how real audit-grade engagements ship (`~/workspace/integer-library`: `specs/` package depending on the production package; design doc L1) and it keeps the deployed package pristine — no `#[spec_only]`, no prover dependency, no marker blocks.

The Asymptotic SKILL.md also warns colocation is fragile:

> Specs may cause compile errors when placed alongside regular Move code due to prover-specific changes in the compilation pipeline. If this happens, create a separate package for specs and use the `target` attribute.

So separate-package is both the cleaner deliverable *and* the more robust one. Layout:

```
<pkg>_specs/
  Move.toml          # name = "<Pkg>Specs", edition = "2024.beta", dep <Pkg> = { local = "../<pkg>" }
  sources/
    <mod>_specs.move # one per production module
```

```move
module <pkg>_specs::<mod>_specs;

use <pkg>::<mod>::{<fn>, /* types in the signature */};

#[spec_only]
use prover::prover::{ensures, asserts, requires, clone};

#[spec(prove, target = <fn>)]
public fun <fn>_spec(<params>): <return_type> {
    // requires / asserts / ensures as usual
    let r = <fn>(<args>);   // MUST call the target (failure-taxonomy: spec_target_body_no_call)
    r
}
```

- `target = <fn>` binds the spec to the imported production function; the body must call it.
- Production functions/types use a plain `use <pkg>::<mod>::{...}`; only `prover::*` imports get `#[spec_only]`.
- A function needing a non-default prover invocation goes in a *second* package — see §8.

**`--inline` opt-out.** Only for single trivial modules where a sibling package is overkill. Writes the legacy in-source marker-block twin (§2, no `target =`). Never the default.

## 4. Common patterns

### 4.1 Mirroring `assert!` aborts

Source:
```move
public fun set_fees(lp_fee_bps: u64) {
    assert!(lp_fee_bps < BPS_IN_100_PCT, EInvalidFeeParam);
    // ...
}
```

Spec — drop the error tag, keep the predicate:
```move
#[spec(prove)]
fun set_fees_spec(lp_fee_bps: u64) {
    asserts(lp_fee_bps < BPS_IN_100_PCT);
    set_fees(lp_fee_bps);
}
```

### 4.2 Overflow handling

`u64` arithmetic that could overflow needs Integer math (lifts to unbounded integers). Source:
```move
public fun add(x: u64, y: u64): u64 { x + y }
```

Spec:
```move
#[spec(prove)]
fun add_spec(x: u64, y: u64): u64 {
    requires(x.to_int().add(y.to_int()).lte(MAX_U64.to_int()));
    let r = add(x, y);
    ensures(r.to_int() == x.to_int().add(y.to_int()));
    r
}
```

### 4.3 Capturing pre-state for `&mut` parameters

Source:
```move
public fun deposit(pool: &mut Pool, amount: u64) {
    pool.balance = pool.balance + amount;
}
```

Spec uses `clone!`:
```move
#[spec(prove)]
fun deposit_spec(pool: &mut Pool, amount: u64) {
    let __old = clone!(pool);
    requires(__old.balance.to_int().add(amount.to_int()).lte(MAX_U64.to_int()));
    deposit(pool, amount);
    ensures(pool.balance == __old.balance + amount);
}
```

### 4.4 Quantifiers — named pure helpers required

Lambdas inside `forall!` / `exists!` must call a named `#[ext(pure)]` function. Inline expressions like `|x| *x + 10` are NOT supported.

```move
#[ext(pure)]
fun is_positive(x: &u64): bool { *x > 0 }

#[spec(prove)]
fun all_positive_spec(v: &vector<u64>): bool {
    let r = all_positive(v);
    ensures(r == forall!(v, |x| is_positive(x)));
    r
}
```

### 4.5 `bag::contains` vs `bag::borrow`

`bag::contains<K>` does **not** discharge the abort condition of `bag::borrow<K, V>`. Always use `bag::contains_with_type<K, V>` when the function under spec calls `bag::borrow<K, V>`.

### 4.6 Loop invariants

When a spec touches a variable modified inside a loop, an `invariant!` is required:

```move
#[spec(prove)]
fun sum_spec(v: &vector<u64>): u64 {
    let r = sum(v);
    invariant!(|| { /* relation between accumulator and partial result */ });
    ensures(r == /* expected closed form */);
    r
}
```

### 4.7 Ghost state for events

If the function under spec emits an event and the spec needs to reason about it. The helper that mirrors the emit stays a plain `fun` -- do NOT add `#[ext(pure)]`, the body has the `event::emit` side effect that `pure` forbids:

```move
fun emit_large_withdraw_event() {
    event::emit(LargeWithdrawEvent {});
    requires(*global<LargeWithdrawEvent, bool>());
}

#[spec(prove)]
fun withdraw_spec<T>(pool: &mut Pool<T>, shares: Balance<LP<T>>): Balance<T> {
    declare_global<LargeWithdrawEvent, bool>();
    let r = withdraw(pool, shares);
    if (r.value() >= LARGE_WITHDRAW_AMOUNT) {
        ensures(*global<LargeWithdrawEvent, bool>());
    };
    r
}
```

### 4.8 `no_opaque` — see through the callee

By default, the prover treats each function as opaque (uses its spec contract only). When the caller's spec needs to see the callee's actual body:

```move
#[spec(prove, no_opaque)]
fun foo_spec(x: &mut u8) { foo(x); }   // forces inlining of foo's body

#[spec(prove)]
fun bar_spec(x: &mut u8) {
    bar(x);
    ensures(*x == 70);   // discharges because foo_spec is no_opaque
}
```

### 4.9 Per-spec `boogie_opt` tuning

For hard specs (large path explosion), tune Boogie's VC-splitter directly. The AMM uses these on three of its hardest specs:

```move
#[spec(prove, boogie_opt = b"vcsMaxKeepGoingSplits:2 vcsSplitOnEveryAssert vcsFinalAssertTimeout:600")]
fun withdraw_spec<A, B>(pool: &mut Pool<A, B>, lp_in: Balance<LP<A, B>>): (Balance<A>, Balance<B>) { ... }
```

**Never strip these tokens** during spec rewrites. They're load-bearing — without them the spec times out.

### 4.10 Axiomatic modeling of stub callees

Real-world Move packages often depend on libraries whose **source isn't shipped** — the dep's public-bytecode interface is exported but every function body is `abort 0` (the canonical stub shape used when a vendor publishes the ABI but keeps the implementation closed). A prover invoked on such a package concludes every caller path aborts (because every callee aborts), so any spec verifies *vacuously*: the `_Check` and `_Assume` subchecks pass but say nothing about the real math.

The fix is **axiomatic modeling** of the stub callees via a dedicated file in the **spec package** (the default layout, §3) — `<pkg>_specs/sources/specify_axioms.move`. The axioms target the stubbed callees of the production package's deps; keeping them in the spec package means the production source stays untouched:

```move
module <pkg>_specs::specify_axioms;

#[spec_only]
use prover::prover::{fresh};
use utilities::fixed;

// Opaque summary: skip tells the prover not to verify the body; target =
// registers this function as the abstract contract substituted at every
// call site of the target. `fresh()` returns an unconstrained symbolic value
// — the prover knows nothing more than the function's signature.
#[spec(skip, target = fixed::mul_down)]
fun mul_down_spec(_a: u256, _b: u256): u256 { fresh() }

#[spec(skip, target = fixed::mul_up)]
fun mul_up_spec(_a: u256, _b: u256): u256 { fresh() }

#[spec(skip, target = fixed::ln)]
fun ln_spec(_x: u256): u256 { fresh() }

#[spec(skip, target = fixed::exp)]
fun exp_spec(_x: u256): u256 { fresh() }
```

Then write the real spec normally in the target file:

```move
#[spec(prove, ignore_abort)]
fun calc_invariant_full_spec(
    balances: &vector<u128>,
    weights: &vector<u64>,
): u256 {
    let r = calc_invariant_full(balances, weights);
    // ensures(r matches the math you actually care about)
    r
}
```

The prover substitutes the axioms' `fresh()` results at every `fixed::mul_down` / `fixed::ln` / etc. call site inside `calc_invariant_full`, so verification reasons about *symbolic* fixed-point values — not about `abort 0`. The spec doesn't *prove* the real math, but it does prove the spec's structural claims (typing, modular composition, abort behavior) hold under any valid implementation of the stub interface. That's the strongest verification possible without the dep's source.

**When to use:**

- Any dep with `abort 0` bodies for every public function.
- Closed-source math packages (fixed-point libs, oracle clients).
- Performance-critical native functions where the Move impl is a `native fun` stub.

**Caveats:**

- The `skip` attribute prevents the axiom body from being verified — that's the point, since `fresh()` has no postcondition. Don't use `skip` for functions you *do* want verified.
- The `#[spec(target = X)]` requires the spec function's body to actually call `X` *unless* `skip` is also set. The combined `#[spec(skip, target = X)]` form sidesteps that requirement (see failure-taxonomy entry for `spec_target_body_no_call`).
- Add `ensures(...)` only if you can state a property the real implementation *must* satisfy regardless of internals (e.g., `mul_down(a, 0)` must equal `0`). Bare `fresh()` axioms are the safest starting point.

This pattern was discovered during the `move-amm-public` evaluation when the agent observed the `utilities::fixed` source was a stub and the naïve approach (replacing stub bodies with placeholders) silently weakened the verification. The sidecar form makes the axiomatization explicit and reviewable.

## 5. Legacy MSL — DO NOT emit

The Sui Prover does **not** use the legacy Move Prover MSL keywords. Common drift to avoid:

| Don't emit | Use instead |
|---|---|
| `aborts_if cond` | `asserts(cond)` (positive form — "aborts unless cond") |
| `pragma X = Y` | attribute params: `#[spec(prove, X)]` or `#[ext(...)]` |
| `apply X to ...` | `#[spec(prove, include = <path>)]` |
| `assume cond` | put `cond` in `requires(...)` — there is no separate `assume` |
| free `axiom { ... }` | `#[ext(axiom)]` on a function or `#[spec_only(axiom)]` |
| `invariant <expr>` block | `invariant!` macro (loops) or `<Type>_inv` naming + `#[spec_only(inv_target = T)]` (data invariants) |

If a user pastes legacy MSL into a spec the skill is reviewing, surface this table and ask whether to translate or abort.

## 6. Modeling a custom numeric type (the `Integer` math-domain idiom)

For any package with a custom numeric type — a `struct` wrapping an integer field (signed ints, fixed-point, Q64.64, etc.) — specs must reason in the **unbounded mathematical domain** `std::integer::Integer`, not in machine bits. Lift each value with `.to_int()`, do the math in `Integer`, compare. The prover then never wrestles with two's-complement bit-fiddling, which is otherwise intractable. (Pattern distilled from `~/workspace/integer-library`'s verified `i128_specs.move`, L3.)

**Model the type once, at the top of the spec module, then reuse via `use fun`:**

```move
module integer_library_specs::i128_specs;

use integer_library::i128::I128;       // + the functions being spec'd

#[spec_only] use std::integer::Integer;
#[spec_only] use prover::prover::{ensures, asserts};

const MIN_AS_U128: u128 = 0x80000000000000000000000000000000;
const MAX_AS_U128: u128 = 0x7fffffffffffffffffffffffffffffff;

// 1. Reinterpret the raw bits as a signed mathematical integer (two's complement).
#[spec_only]
fun to_signed_int(x: u128): Integer {
    if (x <= MAX_AS_U128) { x.to_int() }
    else { x.to_int().sub(0x100000000000000000000000000000000u256.to_int()) }
}

// 2. Lift the wrapper type into the math domain.
#[spec_only]
fun to_int(v: I128): Integer { v.as_u128().to_signed_int() }

// 3. Range predicate — "does this math value fit the type?" (drives abort specs).
#[spec_only]
fun is_i128(v: Integer): bool {
    v.gte(MIN_AS_U128.to_signed_int()) && v.lte(MAX_AS_U128.to_signed_int())
}

// 4. Domain-specific helper ops, also in Integer space.
#[spec_only]
public fun int_div_trunc(x: Integer, y: Integer): Integer {
    let q = x.abs().div(y.abs());
    if (x.is_pos() && y.is_pos() || x.is_neg() && y.is_neg()) { q } else { q.neg() }
}

// 5. `use fun` aliases so specs read like the math.
use fun to_int as I128.to_int;
use fun to_signed_int as u128.to_signed_int;
use fun int_div_trunc as Integer.div_trunc;
```

With the model in place, specs are short and legible — the abort contract uses the range predicate, the postcondition states the math:

```move
#[spec(prove, target = add)]
public fun add_spec(num1: I128, num2: I128): I128 {
    let sum = num1.to_int().add(num2.to_int());
    asserts(is_i128(sum));                 // aborts iff the true sum doesn't fit
    let result = add(num1, num2);
    ensures(result.to_int() == sum);        // exact, in Integer space
    result
}
```

**Phase 4.3 should emit this model block first** when it detects a wrapper struct over an integer field, before any per-function spec. Put it once per spec module (or a shared spec module imported by the others).

## 7. Defining-property postconditions (prefer over recomputation)

The weakest useful `ensures` is `result == <recompute the formula>`: it re-derives the implementation in spec language, so a wrong mental model passes against a wrong implementation. Prefer the **defining property** — the algebraic relation that characterizes the result regardless of how it's computed. (From integer-library's `full_math` / `math_u256` specs, L4.)

| Function | Recomputation (weak) | Defining property (strong) |
|---|---|---|
| floor div `mul_div_floor` | `result == p / d` | `result*d <= p  &&  p < (result+1)*d` |
| `div_mod` | `(p, r) == (num/d, num%d)` | `p*d + r == num  &&  r < d` |
| ceil div | `result == (p + d-1)/d` | `(result-1)*d < p  &&  p <= result*d` |
| `add_check` (overflow test) | mirror the impl's branch | `result == (a+b <= MAX)` in Integer space |

Real example — note the functional `ensures` *and* the bounding inequalities together:

```move
#[spec(prove, target = mul_div_floor)]
public fun mul_div_floor_spec(num1: u64, num2: u64, denom: u64): u64 {
    asserts(denom > 0);
    let product = num1.to_int().mul(num2.to_int());
    let expected = product.div(denom.to_int());
    asserts(expected.lte(std::u64::max_value!().to_int()));
    let result = mul_div_floor(num1, num2, denom);
    ensures(result.to_int() == expected);                                   // functional
    ensures(result.to_int().mul(denom.to_int()).lte(product));              // result*d <= p
    ensures(product.lt(result.to_int().add(1u64.to_int()).mul(denom.to_int()))); // p < (result+1)*d
    result
}
```

Offer defining-property as the recommended postcondition tier in Phase 4.2 for division, rounding, sqrt, and any inverse-relation function. These inequalities *are* the report's "Proof obligations" (Phase 5).

## 8. Multiple spec packages & custom prover configs

A single production package can need **more than one spec package**, each proved with a different prover invocation. The canonical case (integer-library, L5): bit-exact bitwise/shift/wrapping semantics can't be modeled in the default integer encoding and must be proved with `--no-bv-int-encoding` (bitvector encoding). Those specs live in a second package:

```
<pkg>_specs/      → sui-prover                       # default integer encoding
<pkg>_specs_bv/   → sui-prover --no-bv-int-encoding  # bit-exact semantics
```

- Create `<pkg>_specs_bv/` **lazily** — only when a spec fails/times out and the diagnosis points at bit-level reasoning (Phase 4.6).
- Record each function's package + flag set in `.specify-progress.json` `prover_flags` and surface it in the report — *which encoding a function needed is itself audit signal* (it tells you the property is bit-level).
- In the bv package the proof sometimes needs a `native fun` bound to a Boogie procedure (e.g. `ashr`) plus a custom prelude — see below.

### 8.1 `prelude_extra.bpl` — hand-written axioms (TRUSTED, NOT PROVED)

When Boogie can't derive a fact, the engagement adds it as an axiom in a `prelude_extra.bpl` shipped beside the spec package's `Move.toml`. integer-library's prelude teaches Boogie things like:

```
axiom (forall x: int :: {$xorInt'u128'(x, $MAX_U128)} $xorInt'u128'(x, $MAX_U128) == $MAX_U128 - x);
axiom (forall x: int :: {$andInt'u128'(x, $LO_64_MASK)} $andInt'u128'(x, $LO_64_MASK) == x mod $TWO_POW_64);
axiom (forall x: int :: {$shr(x, 127)} $shr(x, 127) == x div $TWO_POW_127);
```

…and the bv prelude binds a native `ashr` to `$AShr'BvN'`.

**Every line in `prelude_extra.bpl` is a hole in the verification.** An axiom is assumed true, never checked — if it's wrong, every proof that relies on it is vacuous. Therefore:

- Treat the prelude as an **escape hatch of last resort**, after `requires`-strengthening, `no_opaque`, `--split-paths`, and `boogie_opt` (failure-taxonomy `timeout` / `ensures_failed`) have failed.
- **Every axiom must be disclosed** in the report's "Trusted axioms — not proved" section (Phase 5, L6): the axiom, the file+line, and a prose justification of why it's sound. This is the single most audit-critical content in the deliverable.
- Prefer the narrowest axiom that unblocks the proof (a single masking identity), never a broad one.
