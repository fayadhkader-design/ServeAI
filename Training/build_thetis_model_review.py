#!/usr/bin/env python3
"""Build a searchable local audit for the multi-player THETIS experiment."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path

import numpy as np

from train_temporal_baseline import PHASES, TECHNIQUES, record_vector


ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent
DEFAULT_DATASET = ROOT / "artifacts/thetis_pseudo_coach_dataset.json"
DEFAULT_MODEL = ROOT / "artifacts/thetis_pseudo_coach_model.json"
DEFAULT_EVALUATION = ROOT / "artifacts/thetis_pseudo_coach_evaluation.json"
DEFAULT_MANIFEST = ROOT / "artifacts/thetis_source_manifest.json"
DEFAULT_PARITY = ROOT / "artifacts/thetis_coreml_parity.json"
DEFAULT_OUTPUT = WORKSPACE / "outputs/serveai-multiplayer-model-audit.html"


def predictions(model: dict, record: dict) -> dict[str, np.ndarray]:
    vector = record_vector(record)
    mean = np.asarray(model["normalizationMean"], dtype=np.float64)
    scale = np.asarray(model["normalizationScale"], dtype=np.float64)
    normalized = (vector - mean) / scale
    result = {}
    for name, head in model["heads"].items():
        result[name] = normalized @ np.asarray(head["weights"]) + np.asarray(head["intercept"])
    return result


def review_record(model: dict, record: dict, video_paths: dict[str, str]) -> dict:
    predicted = predictions(model, record)
    duration = record["featureEvidence"]["sequence"]["duration"]
    truth_boundaries = {
        item["phase"]: item for item in record["labels"]["phaseBoundaries"]
    }
    boundary_errors = []
    phases = []
    for index, phase in enumerate(PHASES):
        truth = truth_boundaries[phase]
        if truth["isVisible"]:
            start = float(np.clip(predicted["boundaries"][index * 2], 0, 1)) * duration
            end = float(np.clip(predicted["boundaries"][index * 2 + 1], 0, 1)) * duration
            boundary_errors.extend([
                abs(start - truth["startTime"]),
                abs(end - truth["endTime"]),
            ])
            phases.append({
                "phase": phase,
                "start": truth["startTime"],
                "end": truth["endTime"],
                "predictedStart": start,
                "predictedEnd": end,
                "note": truth["note"],
            })

    truth_ratings = {
        item["label"]: item for item in record["labels"]["techniqueRatings"]
    }
    ratings = []
    rating_errors = []
    for index, technique in enumerate(TECHNIQUES):
        legacy_key = "tossConsistency" if technique == "tossPlacement" else technique
        truth = truth_ratings.get(technique, truth_ratings.get(legacy_key))
        if truth is None:
            raise RuntimeError(f"review record is missing technique label {technique}")
        predicted_rating = 1 + float(np.clip(predicted["ratings"][index], 0, 1)) * 4
        if truth["isVisible"]:
            rating_errors.append(abs(predicted_rating - truth["rating"]))
        ratings.append({
            "label": technique,
            "truth": truth["rating"],
            "predicted": predicted_rating if truth["isVisible"] else None,
            "visible": truth["isVisible"],
            "note": truth["note"],
        })
    predicted_priority = TECHNIQUES[int(np.argmax(predicted["priority"]))]
    player_number = int(record["participantPseudonym"].rsplit("p", 1)[1])
    return {
        "analysisID": record["analysisID"],
        "player": record["participantPseudonym"],
        "playerNumber": player_number,
        "split": record["split"],
        "skill": record["cohorts"]["skillLevel"],
        "serveType": record["cohorts"]["serveType"].replace("ser", ""),
        "video": "../" + video_paths[record["sourceVideoSHA256"]],
        "duration": duration,
        "boundaryMAE": float(np.mean(boundary_errors)),
        "ratingMAE": float(np.mean(rating_errors)) if rating_errors else None,
        "truthPriority": record["labels"]["topPriority"],
        "predictedPriority": predicted_priority,
        "priorityMatches": predicted_priority == record["labels"]["topPriority"],
        "phases": phases,
        "ratings": ratings,
    }


def build_html(dataset: dict, model: dict, evaluation: dict, manifest: dict, parity: dict) -> str:
    video_paths = {item["derivedSHA256"]: item["derivedPath"] for item in manifest["files"]}
    records = [review_record(model, record, video_paths) for record in dataset["records"]]
    test = evaluation["testPseudoTeacherAgreement"]
    payload = json.dumps({
        "records": records,
        "rejections": dataset["segmentation"]["rejections"],
    }, separators=(",", ":")).replace("</", "<\\/")
    metrics = [
        ("Unique serves", f"{len(records)}", True),
        ("Players", f"{sum(dataset['playerCounts'].values())}", True),
        ("Held-out test", f"{test['clipCount']} clips · {test['playerCount']} players", True),
        ("Phase timing", f"{test['boundaryMeanAbsoluteErrorSeconds']:.3f}s", test["boundaryMeanAbsoluteErrorSeconds"] <= 0.12),
        ("Technique error", f"{test['techniqueRatingMeanAbsoluteError']:.2f}", test["techniqueRatingMeanAbsoluteError"] <= 0.60),
        ("Priority agreement", f"{test['priorityAgreement']:.0%}", test["priorityAgreement"] >= 0.75),
        ("Core ML parity", f"{parity['maximumAbsoluteError']:.2g}", parity["passes"]),
    ]
    metric_markup = "".join(
        f'<div class="metric"><span>{html.escape(label)}</span><strong>{html.escape(value)}</strong><small class="{"pass" if passed else "fail"}">{"PASS" if passed else "FAIL"}</small></div>'
        for label, value, passed in metrics
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ServeAI · Multi-player model audit</title>
<style>
:root{{--bg:#090b11;--surface:#121621;--surface2:#191f2c;--ink:#f7f8fb;--muted:#aeb7c8;--line:#2b3343;--lime:#d7ff3f;--gold:#ffc857;--red:#ff6b75;--blue:#84a9ff;--radius:14px;color-scheme:dark}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}} button,input,select{{font:inherit}}
.shell{{max-width:1500px;margin:auto;padding:32px 24px 64px}} header{{display:flex;gap:24px;align-items:flex-end;justify-content:space-between;border-bottom:1px solid var(--line);padding-bottom:24px}}
.brand{{font-weight:850;letter-spacing:-.03em;font-size:clamp(30px,5vw,64px);line-height:.95;max-width:12ch;text-wrap:balance}} .brand em{{color:var(--lime);font-style:normal}}
.lede{{max-width:66ch;color:var(--muted);margin:12px 0 0}} .status{{max-width:430px;background:#2a2112;color:#ffe7a6;padding:14px 16px;border-radius:var(--radius)}}
.metrics{{display:flex;gap:0;overflow-x:auto;margin:28px 0;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}} .metric{{min-width:165px;padding:18px;border-right:1px solid var(--line)}}
.metric span,.metric small{{display:block;color:var(--muted);font-size:12px}} .metric strong{{display:block;font-size:24px;margin:3px 0}} .metric small.pass{{color:var(--lime)}} .metric small.fail{{color:var(--red)}}
.controls{{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:22px 0}} input,select,button{{min-height:44px;border:1px solid var(--line);background:var(--surface);color:var(--ink);border-radius:10px;padding:10px 12px}} input{{min-width:260px;flex:1}} button{{cursor:pointer}} button:hover,button:focus-visible{{border-color:var(--lime)}}
.count{{color:var(--muted);margin-left:auto}} .table-wrap{{overflow:auto;border:1px solid var(--line);border-radius:var(--radius)}} table{{width:100%;border-collapse:collapse;min-width:1000px}} th{{position:sticky;top:0;background:var(--surface2);text-align:left;color:var(--muted);font-size:12px;padding:12px;z-index:1}} td{{padding:12px;border-top:1px solid var(--line);vertical-align:middle}} tbody tr:hover{{background:#151a25}} .mono{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}} .tag{{display:inline-block;padding:3px 8px;border-radius:999px;background:var(--surface2);color:var(--muted)}} .yes{{color:var(--lime)}} .no{{color:var(--red)}}
.pager{{display:flex;justify-content:flex-end;align-items:center;gap:10px;margin-top:14px}} dialog{{width:min(940px,calc(100% - 24px));max-height:calc(100% - 24px);border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);color:var(--ink);padding:0}} dialog::backdrop{{background:#000b}} .dialog-head{{position:sticky;top:0;background:var(--surface);display:flex;justify-content:space-between;gap:16px;padding:16px;border-bottom:1px solid var(--line);z-index:2}} .dialog-body{{padding:18px}} video{{display:block;width:100%;max-height:480px;background:#000;border-radius:10px}} .detail-grid{{display:grid;grid-template-columns:1fr 1fr;gap:22px;margin-top:18px}} h2,h3{{margin:0 0 10px;text-wrap:balance}} ul{{margin:0;padding-left:20px}} li{{margin:8px 0;color:var(--muted)}} li strong{{color:var(--ink)}}
.disclosure{{margin-top:26px;border-top:1px solid var(--line);padding-top:20px;color:var(--muted);max-width:75ch}} .rejections{{margin-top:26px}} details{{border-top:1px solid var(--line);padding:14px 0}} summary{{cursor:pointer;font-weight:700}}
@media(max-width:760px){{.shell{{padding:20px 14px 48px}} header{{display:block}} .status{{margin-top:18px}} .detail-grid{{grid-template-columns:1fr}} .count{{width:100%;margin-left:0}}}}
@media(prefers-reduced-motion:reduce){{*{{scroll-behavior:auto!important}}}}
</style>
</head>
<body><main class="shell">
<header><div><div class="brand">ServeAI <em>model audit</em></div><p class="lede">Every usable THETIS serve is player-isolated, pseudo-labeled from observable Apple Vision joints, and linked to its local source clip. Open any row to compare rule labels with the frozen model.</p></div><div class="status"><strong>Experimental only.</strong><br>Technique and coaching-priority gates failed. The source is frontal, staged, no-ball footage licensed for research—not a production side/rear coaching model.</div></header>
<section class="metrics" aria-label="Evaluation summary">{metric_markup}</section>
<div class="controls"><input id="search" type="search" placeholder="Search clip or player" aria-label="Search clips"><select id="split" aria-label="Filter by split"><option value="">All splits</option><option>train</option><option>validation</option><option>test</option></select><select id="type" aria-label="Filter by serve type"><option value="">All serve types</option><option value="flat">flat</option><option value="kick">kick</option><option value="slice">slice</option></select><select id="match" aria-label="Filter by priority agreement"><option value="">All priority results</option><option value="yes">priority matches</option><option value="no">priority differs</option></select><span class="count" id="count"></span></div>
<div class="table-wrap"><table><thead><tr><th>Clip</th><th>Player</th><th>Split</th><th>Serve</th><th>Phase MAE</th><th>Rating MAE</th><th>Rule priority</th><th>Model priority</th><th>Review</th></tr></thead><tbody id="rows"></tbody></table></div>
<div class="pager"><button id="previous">Previous</button><span id="page"></span><button id="next">Next</button></div>
<section class="rejections"><details><summary>{dataset['segmentation']['rejectedClipCount']} excluded source clips</summary><p class="lede">Thirty-nine lacked a reliable overhead-arm event; one was an exact source duplicate. These clips were not force-labeled.</p><div id="rejections"></div></details></section>
<p class="disclosure">Core ML conversion parity passed at {parity['maximumAbsoluteError']:.3g} maximum absolute error over {parity['sampleCount']} held-out samples. This confirms format conversion only. It does not measure coaching truth, real-court behavior, side/rear accuracy, repeatability, or commercial clearance.</p>
</main>
<dialog id="detail"><div class="dialog-head"><div><h2 id="detail-title"></h2><div class="mono" id="detail-meta"></div></div><button id="close" aria-label="Close review">Close</button></div><div class="dialog-body"><video id="video" controls preload="metadata" playsinline></video><div class="detail-grid"><section><h3>Phase labels</h3><ul id="phases"></ul></section><section><h3>Technique labels</h3><ul id="ratings"></ul></section></div></div></dialog>
<script id="data" type="application/json">{payload}</script>
<script>
const data=JSON.parse(document.getElementById('data').textContent),state={{page:0,pageSize:50}};
const $=id=>document.getElementById(id), esc=s=>String(s).replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
function filtered(){{const q=$('search').value.trim().toLowerCase(),sp=$('split').value,tp=$('type').value,mp=$('match').value;return data.records.filter(r=>(!q||(r.analysisID+' '+r.player).toLowerCase().includes(q))&&(!sp||r.split===sp)&&(!tp||r.serveType===tp)&&(!mp||(mp==='yes')===r.priorityMatches));}}
function render(){{const all=filtered(),pages=Math.max(1,Math.ceil(all.length/state.pageSize));state.page=Math.min(state.page,pages-1);const items=all.slice(state.page*state.pageSize,(state.page+1)*state.pageSize);$('rows').innerHTML=items.map(r=>`<tr><td class="mono">${{esc(r.analysisID)}}</td><td>${{esc(r.player)}}</td><td><span class="tag">${{esc(r.split)}}</span></td><td>${{esc(r.serveType)}}</td><td>${{r.boundaryMAE.toFixed(3)}}s</td><td>${{r.ratingMAE?.toFixed(2)??'—'}}</td><td>${{esc(r.truthPriority)}}</td><td class="${{r.priorityMatches?'yes':'no'}}">${{esc(r.predictedPriority)}}</td><td><button data-id="${{esc(r.analysisID)}}">Open clip</button></td></tr>`).join('');$('count').textContent=`${{all.length}} clips`;$('page').textContent=`Page ${{state.page+1}} of ${{pages}}`;$('previous').disabled=state.page===0;$('next').disabled=state.page>=pages-1;$('rows').querySelectorAll('button').forEach(b=>b.onclick=()=>openRecord(b.dataset.id));}}
function openRecord(id){{const r=data.records.find(x=>x.analysisID===id);$('detail-title').textContent=r.analysisID;$('detail-meta').textContent=`${{r.player}} · ${{r.split}} · ${{r.serveType}} serve · ${{r.duration.toFixed(2)}}s`;$('video').src=r.video;$('phases').innerHTML=r.phases.map(x=>`<li><strong>${{esc(x.phase)}}</strong> rule ${{x.start.toFixed(2)}}–${{x.end.toFixed(2)}}s · model ${{x.predictedStart.toFixed(2)}}–${{x.predictedEnd.toFixed(2)}}s<br>${{esc(x.note)}}</li>`).join('');$('ratings').innerHTML=r.ratings.map(x=>`<li><strong>${{esc(x.label)}}</strong> ${{x.visible?`rule ${{x.truth}}/5 · model ${{x.predicted.toFixed(1)}}/5`:'unavailable'}}<br>${{esc(x.note)}}</li>`).join('');$('detail').showModal();}}
['search','split','type','match'].forEach(id=>$(id).addEventListener('input',()=>{{state.page=0;render()}}));$('previous').onclick=()=>{{state.page--;render()}};$('next').onclick=()=>{{state.page++;render()}};$('close').onclick=()=>$('detail').close();$('detail').addEventListener('close',()=>{{$('video').pause();$('video').removeAttribute('src');$('video').load()}});$('rejections').innerHTML=data.rejections.map(x=>`<div class="mono">${{esc(x.sourceFilename)}} — ${{esc(x.reason)}}</div>`).join('');render();
</script></body></html>"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--evaluation", type=Path, default=DEFAULT_EVALUATION)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--parity", type=Path, default=DEFAULT_PARITY)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    inputs = [json.loads(path.read_text()) for path in (args.dataset, args.model, args.evaluation, args.manifest, args.parity)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(build_html(*inputs))
    print(f"wrote multi-player model audit to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
