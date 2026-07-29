#!/usr/bin/env python3
"""Build a self-contained visual audit of pseudo labels and model outputs."""

from __future__ import annotations

import argparse
import base64
import html
import io
import json
from pathlib import Path

import numpy as np

from train_pseudo_coach_baseline import fit_candidate, load_pseudo_dataset
from train_temporal_baseline import TECHNIQUES, predict


ROOT = Path(__file__).resolve().parent
DEFAULT_DATASET = ROOT / "artifacts/pseudo_coach_dataset.json"
DEFAULT_EVALUATION = ROOT / "artifacts/pseudo_coach_evaluation.json"
DEFAULT_OUTPUT = ROOT.parent / "outputs/serveai-pseudo-label-review.html"

TITLES = {
    "tossPlacement": "Toss placement",
    "loadingSequence": "Loading sequence",
    "trophyAlignment": "Trophy alignment",
    "legDriveTiming": "Leg-drive timing",
    "contactReach": "Contact reach",
    "landingBalance": "Landing balance",
}


def image_data_uri(path: Path) -> str:
    try:
        from PIL import Image
    except ImportError as error:
        raise RuntimeError("Pillow is required to embed review thumbnails") from error
    with Image.open(path) as source:
        image = source.convert("RGB")
        image.thumbnail((360, 210))
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=76, optimize=True)
    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()


def rating_marks(value: float | int | None) -> str:
    if value is None:
        return '<span class="unavailable">Unavailable</span>'
    rounded = int(round(float(value)))
    dots = "".join(
        f'<span class="rating-dot{" active" if index <= rounded else ""}" aria-hidden="true"></span>'
        for index in range(1, 6)
    )
    return f'<span class="rating" aria-label="{float(value):.1f} out of 5">{dots}<strong>{float(value):.1f}</strong></span>'


def clip_html(record: dict, prediction: dict, image_root: Path) -> str:
    provenance = record["featureEvidence"]["provenance"]
    source_range = provenance["sourceFrameRange"]
    events = record["pseudoLabelProvenance"]["events"]
    frame_numbers = [
        ("Start", source_range["startFrame"]),
        ("Load", events["loadingFrame"]),
        ("Trophy proxy", events["overheadTrophyProxyFrame"]),
        ("Contact proxy", events["overheadContactProxyFrame"]),
        ("Finish", source_range["endFrame"]),
    ]
    filmstrip = []
    for label, frame_number in frame_numbers:
        path = image_root / f"S_{frame_number:03d}.jpeg"
        if not path.exists():
            raise RuntimeError(f"review image is missing: {path}")
        filmstrip.append(
            f'<figure><img src="{image_data_uri(path)}" alt="{html.escape(label)} at source frame {frame_number}">'
            f'<figcaption>{html.escape(label)} <span>#{frame_number}</span></figcaption></figure>'
        )

    teacher = {item["label"]: item for item in record["labels"]["techniqueRatings"]}
    rows = []
    for index, technique in enumerate(TECHNIQUES):
        legacy_key = "tossConsistency" if technique == "tossPlacement" else technique
        item = teacher.get(technique, teacher.get(legacy_key))
        if item is None:
            raise RuntimeError(f"review record is missing technique label {technique}")
        predicted_rating = 1 + 4 * float(prediction["ratings"][index])
        model_visible = float(prediction["techniqueVisibility"][index]) >= 0.5
        if not item["isVisible"]:
            model_cell = '<span class="unavailable">Not trained</span>'
        else:
            model_cell = rating_marks(predicted_rating) if model_visible else '<span class="unavailable">Predicted unavailable</span>'
        rows.append(
            "<tr>"
            f'<th scope="row">{html.escape(TITLES[technique])}</th>'
            f'<td>{rating_marks(item["rating"])}</td>'
            f'<td>{model_cell}</td>'
            f'<td class="evidence">{html.escape(item["note"])}</td>'
            "</tr>"
        )

    priority_index = int(np.argmax(prediction["priority"]))
    predicted_priority = TECHNIQUES[priority_index]
    split = record["split"]
    return f"""
    <article class="clip" data-split="{split}">
      <header class="clip-head">
        <div>
          <h2>{html.escape(record['analysisID'].replace('pseudo-', 'Serve '))}</h2>
          <p>Source frames {source_range['startFrame']}–{source_range['endFrame']} · {source_range['frameCount']} original frames</p>
        </div>
        <div class="clip-tags">
          <span class="tag split-{split}">{split.title()} block</span>
          <span class="tag">Teacher priority: {html.escape(TITLES[record['labels']['topPriority']])}</span>
          <span class="tag">Model priority: {html.escape(TITLES[predicted_priority])}</span>
        </div>
      </header>
      <div class="filmstrip">{''.join(filmstrip)}</div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Technique</th><th>Rule label</th><th>Model estimate</th><th>Observable evidence</th></tr></thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
      <p class="clip-warning">{html.escape(events['observableWarning'])}</p>
    </article>
    """


def build_review(dataset: dict, evaluation: dict, image_root: Path) -> str:
    records = dataset["records"]
    trained = fit_candidate(records, float(evaluation["selectedL2"]))
    predictions = predict(trained)
    clip_sections = []
    for index, record in enumerate(records):
        prediction = {name: values[index] for name, values in predictions.items()}
        clip_sections.append(clip_html(record, prediction, image_root))
    test = evaluation["testTeacherAgreement"]
    sources = json.loads((ROOT / "biomechanics_sources.json").read_text())["sources"]
    source_links = "".join(
        f'<li><a href="{html.escape(item["url"])}">{html.escape(item["title"])}</a></li>'
        for item in sources
    )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ServeAI pseudo-coach audit</title>
  <style>
    :root {{
      color-scheme: dark;
      --court: #08150f;
      --surface: #0c1f16;
      --surface-2: #102a1d;
      --chalk: #f3f5e8;
      --muted: #b9c5bb;
      --line: #31503d;
      --lime: #c6ff3d;
      --cyan: #46d5ff;
      --pink: #ff3d9a;
      --orange: #ff8a3d;
      --focus: #ffffff;
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: var(--court); color: var(--chalk); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.45; }}
    a {{ color: var(--cyan); }}
    a:focus-visible, button:focus-visible {{ outline: 3px solid var(--focus); outline-offset: 3px; }}
    .shell {{ width: min(1480px, calc(100% - 32px)); margin: 0 auto; }}
    .masthead {{ padding: 40px 0 24px; border-bottom: 1px solid var(--line); }}
    .masthead h1 {{ max-width: 16ch; margin: 0 0 12px; font-size: 2.4rem; line-height: 1; letter-spacing: -0.035em; text-wrap: balance; }}
    .masthead > p {{ max-width: 72ch; color: var(--muted); margin: 0; font-size: 1.05rem; text-wrap: pretty; }}
    .status {{ margin: 24px 0 0; padding: 16px; border: 1px solid var(--orange); border-radius: 12px; background: #291a0d; color: #ffe4cf; }}
    .status strong {{ color: #fff; }}
    .summary {{ display: flex; flex-wrap: wrap; gap: 8px 24px; padding: 20px 0; border-bottom: 1px solid var(--line); }}
    .summary div {{ min-width: 150px; }}
    .summary dt {{ color: var(--muted); font-size: .86rem; }}
    .summary dd {{ margin: 2px 0 0; font-variant-numeric: tabular-nums; font-weight: 700; }}
    .toolbar {{ position: sticky; top: 0; z-index: 10; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 12px 0; background: color-mix(in srgb, var(--court) 94%, transparent); backdrop-filter: blur(10px); border-bottom: 1px solid var(--line); }}
    .toolbar span {{ margin-right: 8px; color: var(--muted); }}
    button {{ min-height: 44px; border: 1px solid var(--line); border-radius: 999px; padding: 0 16px; background: var(--surface); color: var(--chalk); font: inherit; cursor: pointer; }}
    button:hover {{ border-color: var(--lime); }}
    button[aria-pressed="true"] {{ background: var(--lime); border-color: var(--lime); color: var(--court); font-weight: 800; }}
    main {{ padding-bottom: 60px; }}
    .clip {{ padding: 28px 0 32px; border-bottom: 1px solid var(--line); }}
    .clip[hidden] {{ display: none; }}
    .clip-head {{ display: flex; align-items: flex-start; justify-content: space-between; gap: 20px; margin-bottom: 16px; }}
    .clip-head h2 {{ margin: 0; font-size: 1.35rem; letter-spacing: -.02em; }}
    .clip-head p {{ margin: 4px 0 0; color: var(--muted); }}
    .clip-tags {{ display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px; }}
    .tag {{ display: inline-flex; align-items: center; min-height: 30px; padding: 3px 10px; border-radius: 999px; background: var(--surface-2); color: var(--chalk); font-size: .82rem; }}
    .split-train {{ color: var(--lime); }} .split-validation {{ color: var(--orange); }} .split-test {{ color: var(--pink); }}
    .filmstrip {{ display: grid; grid-template-columns: repeat(5, minmax(150px, 1fr)); gap: 8px; overflow-x: auto; padding-bottom: 4px; }}
    figure {{ min-width: 150px; margin: 0; background: var(--surface); border-radius: 10px; overflow: hidden; }}
    figure img {{ display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: cover; }}
    figcaption {{ display: flex; justify-content: space-between; gap: 8px; padding: 8px 10px; font-size: .8rem; color: var(--muted); }}
    figcaption span {{ font-variant-numeric: tabular-nums; color: var(--chalk); }}
    .table-wrap {{ margin-top: 16px; overflow-x: auto; }}
    table {{ width: 100%; min-width: 860px; border-collapse: collapse; background: var(--surface); border-radius: 12px; overflow: hidden; }}
    th, td {{ padding: 12px 14px; text-align: left; border-bottom: 1px solid var(--line); vertical-align: top; }}
    thead th {{ color: var(--muted); font-size: .8rem; font-weight: 600; }}
    tbody th {{ width: 170px; font-size: .9rem; }}
    tbody tr:last-child > * {{ border-bottom: 0; }}
    .evidence {{ color: var(--muted); max-width: 60ch; font-size: .88rem; }}
    .rating {{ display: inline-flex; align-items: center; gap: 4px; white-space: nowrap; }}
    .rating strong {{ margin-left: 4px; min-width: 2.2ch; font-variant-numeric: tabular-nums; }}
    .rating-dot {{ width: 8px; height: 8px; border-radius: 50%; background: #48604f; }}
    .rating-dot.active {{ background: var(--lime); }}
    .unavailable {{ color: var(--orange); font-size: .86rem; }}
    .clip-warning {{ margin: 10px 0 0; color: var(--orange); font-size: .86rem; }}
    footer {{ padding: 32px 0 56px; color: var(--muted); }}
    footer h2 {{ color: var(--chalk); font-size: 1.15rem; }}
    footer p, footer ul {{ max-width: 75ch; }}
    @media (max-width: 760px) {{
      .shell {{ width: min(100% - 20px, 1480px); }}
      .masthead {{ padding-top: 28px; }}
      .masthead h1 {{ font-size: 2rem; }}
      .clip-head {{ flex-direction: column; }}
      .clip-tags {{ justify-content: flex-start; }}
      .filmstrip {{ grid-template-columns: repeat(5, 240px); }}
    }}
    @media (prefers-reduced-motion: reduce) {{ * {{ scroll-behavior: auto !important; transition: none !important; }} }}
  </style>
</head>
<body>
  <div class="shell">
    <header class="masthead">
      <h1>Pseudo-coach audit</h1>
      <p>Every complete serve cycle found in the licensed source sequence, with transparent rule labels and the distilled model’s output. Use this to inspect whether the event proxies look sensible—not as proof of coaching accuracy.</p>
      <div class="status" role="note"><strong>Research only.</strong> One athlete, no independent coach labels, no calibrated camera, no verified ball contact, and no racket tracking. This candidate is not active in ServeAI.</div>
      <dl class="summary">
        <div><dt>Complete clips</dt><dd>{len(records)}</dd></div>
        <div><dt>Source athletes</dt><dd>1</dd></div>
        <div><dt>Test rule-rating MAE</dt><dd>{test['techniqueRatingMeanAbsoluteError']:.2f} / 4</dd></div>
        <div><dt>Test priority agreement</dt><dd>{test['priorityAgreement'] * 100:.0f}%</dd></div>
        <div><dt>Test boundary MAE</dt><dd>{test['boundaryMeanAbsoluteErrorSeconds']:.3f}s</dd></div>
        <div><dt>Production eligible</dt><dd>No</dd></div>
      </dl>
    </header>
    <nav class="toolbar" aria-label="Filter serve clips"><span>Show</span>
      <button type="button" data-filter="all" aria-pressed="true">All</button>
      <button type="button" data-filter="train" aria-pressed="false">Train</button>
      <button type="button" data-filter="validation" aria-pressed="false">Validation</button>
      <button type="button" data-filter="test" aria-pressed="false">Test</button>
    </nav>
    <main>{''.join(clip_sections)}</main>
    <footer>
      <h2>What the labels mean</h2>
      <p>The rule label is generated directly from visible 2D joints and source-cited event definitions. The model estimate is what the trained ridge heads predict from the resampled pose sequence. “Unavailable” is intentional whenever the source cannot support the claim.</p>
      <h2>Sources and attribution</h2>
      <ul>{source_links}</ul>
      <p>Source images: Wang, Lai, Huang, and Lin (2024), Tennis Player Actions Dataset for Human Pose Estimation, CC BY 4.0, DOI 10.17632/nv3rpsxhhk.1.</p>
    </footer>
  </div>
  <script>
    const buttons = [...document.querySelectorAll('[data-filter]')];
    const clips = [...document.querySelectorAll('.clip')];
    buttons.forEach(button => button.addEventListener('click', () => {{
      const filter = button.dataset.filter;
      buttons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
      clips.forEach(clip => clip.hidden = filter !== 'all' && clip.dataset.split !== filter);
    }}));
  </script>
</body>
</html>"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--evaluation", type=Path, default=DEFAULT_EVALUATION)
    parser.add_argument("--image-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    try:
        dataset = load_pseudo_dataset(args.dataset)
        evaluation = json.loads(args.evaluation.read_text())
        document = build_review(dataset, evaluation, args.image_root)
    except (OSError, KeyError, TypeError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Review generation stopped: {error}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(document)
    print(f"wrote self-contained pseudo-label review to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
