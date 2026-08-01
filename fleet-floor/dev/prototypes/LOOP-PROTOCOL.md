# Ten verified loops — the request prompt

Paste the block below to start a run. Replace `<TARGET>` with the scene to work
on (e.g. `the admiral bridge`, `the sentinel gallery`, or both).

---

## THE REQUEST

> Run **10 improvement loops** on `<TARGET>`.
>
> **Every loop begins with verification, not with work.** The loop is:
>
> 1. **Render** the current scene to a PNG (`droids.js`), full frame, unit in place.
> 2. **Verify** — spawn a *fresh* subagent that receives **only two things**: that
>    one image, and the CRITIQUE PROMPT below, verbatim. It gets no benchmark
>    images, no source code, no description of what the scene is meant to be, no
>    knowledge of my intent, and no knowledge of any previous loop or score. A new
>    subagent every loop — never continue a previous one, or it will grade its own
>    earlier notes instead of the picture.
> 3. **Record** the score it returns.
> 4. **Fix** — work only on the findings it ranked highest. Do not fix things it
>    did not raise. Do not defend anything it got wrong; if it misread an object,
>    that misreading *is* the defect.
> 5. **Re-render and move to the next loop.** The next loop's verification is what
>    judges this loop's fix.
>
> **Rules that make this strict rather than decorative:**
>
> - The score at **loop 1 is the baseline**, taken *before* any work in this run.
>   The score at **loop 10 is the result**. Report both, plus the full sequence.
> - **Up to 3 attempts per loop.** Aim to one-shot it. If after 3 attempts the
>   score has not moved, stop attempting, write down why, and carry the finding
>   into the next loop rather than burning the run on it.
> - **If a score goes down, revert that loop's changes** and try a different fix.
>   A loop that lowers the score is not "a different opinion"; treat it as a
>   regression.
> - **Commit at the end of every loop** with the score in the message, so the
>   trajectory is reconstructable from git alone.
> - Do not tune the critique prompt between loops. Do not add the benchmark
>   images. Do not tell the verifier what changed. The moment the verifier knows
>   what to look for, it stops being a measurement.
>
> **Report at the end:** the score sequence (`L1 … L10`), what each loop changed,
> which loops moved the number and which did not, and the findings that survived
> all ten loops unfixed.

---

## THE CRITIQUE PROMPT

Given to each verification subagent **verbatim**, alongside exactly one image.

> You are an art director reviewing a single rendered scene. Be harsh, specific
> and concrete. You know nothing about who made it, what it is for, or what it
> was trying to be — judge only what is in front of you.
>
> Look at the image at full resolution. Crop into regions to inspect them
> closely. Sample actual pixel values where a claim depends on it (whether a
> surface is lit, whether two things are the same value, whether an edge exists).
>
> Find the flaws. Work through these six lenses and report what fails in each:
>
> 1. **Design** — is every object identifiable at a glance? Name anything you
>    cannot identify and say what it looks like instead. Does anything look
>    unfinished, arbitrary, or like a rendering artifact rather than an object?
> 2. **Light** — where is the key light, and is it consistent? Does light land on
>    the surfaces it should reach? Do shadows fall in one direction, from one
>    source, with one softness? Is anything lit by nothing, or emitting light
>    with no visible source?
> 3. **Materials** — does metal read as metal, glass as glass, paint as paint? Is
>    any surface flat where it should have a gradient, or glossy where nothing
>    else is? Are the highlights and edge treatments consistent across the scene?
> 4. **Depth** — how many readable planes are there? Does anything float,
>    unmounted, or rest on nothing? Does the ground plane read as a genuine
>    receding surface that things stand on, and does every object make believable
>    contact with what it sits on? Do the seams and edges agree about
>    perspective?
> 5. **Composition** — where does the eye go, and is that the right place? Is
>    there a focal hierarchy, or does everything compete? Is anything crowded,
>    orphaned, badly cropped, or colliding with something else? Is the negative
>    space doing work?
> 6. **Consistency of language** — is the whole image drawn in one idiom? Call
>    out anything with a different line weight, corner radius, level of realism,
>    shadow style, colour saturation, or blur than its neighbours.
>
> Also flag any **scale error**: anything implausibly large or small for what it
> appears to be, measured against the figure in the scene.
>
> Do not list what works. Do not soften. Give a pixel location for every finding.
> Cap the report at the **10 most damaging problems, ranked worst first**.
>
> Then output exactly this, on its own lines, and nothing after it:
>
> ```
> SCORE: N/10
> BIGGEST FLAW: <one sentence>
> TOP 3 FIXES: <three short imperative sentences, highest payoff first>
> ```
>
> The score is overall execution quality, 1 to 10, where 1 is unusable and 10 is
> indistinguishable from professional production art. Be a hard marker: most work
> is a 4 to 6, and you should reserve 8+ for work you would ship without notes.

---

## Why it is shaped this way

- **The verifier is blind on purpose.** Earlier rounds handed it benchmark
  images; it then graded *conformance to the benchmark* rather than the picture.
  With only the image it grades what a viewer actually sees.
- **Verification comes first in the loop, not last.** Fixing before measuring
  means the first score already contains the fix, and the baseline is lost.
- **A fresh subagent every loop.** A continued one anchors on its own earlier
  report and stops looking.
- **"Do not fix what it did not raise"** is the rule that stops the run drifting
  into whatever is most fun to draw. Twice in previous rounds the fix was already
  in the file and something else was covering it — that only surfaces when you
  work the ranked list instead of your own hunch.
