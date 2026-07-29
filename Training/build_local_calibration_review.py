#!/usr/bin/env python3
"""Build a local, source-bound tennis-serve calibration review.

The page collects human review decisions and downloads JSON. It does not grant
consent, create coach ground truth, or add clips to the release dataset.
"""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path

from coach_rubric import VERIFIED_RUBRIC


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "Training/calibration/participant-local-001/calibration_manifest.json"
DEFAULT_OUTPUT = ROOT / "outputs/calibration-participant-local-001/review.html"

PHASES = (
    ("startingStance", "Starting stance"),
    ("ballToss", "Ball toss"),
    ("loading", "Loading"),
    ("trophyPosition", "Trophy position"),
    ("legDrive", "Leg drive"),
    ("racketDrop", "Racket drop"),
    ("upwardAcceleration", "Upward acceleration"),
    ("contactPosition", "Contact position"),
    ("pronation", "Pronation"),
    ("followThrough", "Follow-through"),
)
def frame_paths(output: Path, candidate_id: str) -> list[str]:
    directory = output.parent / "review-frames" / candidate_id
    return [
        path.relative_to(output.parent).as_posix()
        for path in sorted(directory.glob("frame-*.jpg"))
    ]


def build_html(manifest: dict, output: Path) -> str:
    payload = {
        "manifest": manifest,
        "phases": [{"id": key, "label": label} for key, label in PHASES],
        "techniques": [
            {
                "id": item["label"],
                "label": item["title"],
                "observe": item["observe"],
                "requiredVisibility": item["requiredVisibility"],
                "doNotInfer": item["doNotInfer"],
            }
            for item in VERIFIED_RUBRIC["techniques"]
        ],
        "ratingScale": VERIFIED_RUBRIC["ratingScale"],
        "rubric": {
            "identifier": VERIFIED_RUBRIC["rubricIdentifier"],
            "version": VERIFIED_RUBRIC["rubricVersion"],
            "scope": VERIFIED_RUBRIC["scope"],
        },
    }
    for source in payload["manifest"]["sources"]:
        source["video"] = f"media/{Path(source['workingDerivative']).name}"
        for candidate in source["candidates"]:
            candidate["frames"] = frame_paths(output, candidate["id"])
    data = json.dumps(payload, separators=(",", ":")).replace("</", "<\\/")
    source_count = len(manifest["sources"])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ServeAI · Local calibration review</title>
<style>
:root{{--bg:#06150f;--surface:#0d2118;--raised:#142b21;--ink:#f7fbf3;--muted:#b7c7bc;--line:#2c4739;--lime:#c8ff36;--cyan:#35d9ff;--orange:#ff9238;--danger:#ff6f7a;--radius:14px;color-scheme:dark}}
*{{box-sizing:border-box}} html{{scroll-behavior:smooth}} body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
button,input,select,textarea{{font:inherit}} button,select,input,textarea{{border:1px solid var(--line);background:var(--surface);color:var(--ink);border-radius:10px}}
button{{min-height:44px;padding:10px 14px;cursor:pointer;font-weight:720}} button:hover,button:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible{{outline:2px solid var(--lime);outline-offset:2px}}
.shell{{width:min(1180px,100%);margin:auto;padding:28px 20px 80px}} header{{display:grid;grid-template-columns:minmax(0,1fr) minmax(280px,380px);gap:32px;align-items:end;padding-bottom:24px;border-bottom:1px solid var(--line)}}
h1{{font-size:2.4rem;line-height:1.02;letter-spacing:-.035em;margin:0 0 12px;text-wrap:balance}} h2{{font-size:1.45rem;letter-spacing:-.02em;margin:0;text-wrap:balance}} h3{{font-size:1rem;margin:0 0 10px}} p{{max-width:70ch}} .lede,.muted{{color:var(--muted)}} .lede{{margin:0}}
.status{{background:#2a2010;color:#ffe4bb;padding:14px;border-radius:var(--radius)}} .status strong{{color:var(--orange)}}
.progress{{position:sticky;top:0;z-index:10;display:flex;gap:14px;align-items:center;margin:0 -20px;padding:12px 20px;background:color-mix(in srgb,var(--bg) 92%,transparent);border-bottom:1px solid var(--line);backdrop-filter:blur(10px)}} .progress-bar{{height:6px;flex:1;background:var(--raised);border-radius:99px;overflow:hidden}} .progress-bar i{{display:block;width:0;height:100%;background:var(--lime);transition:width .2s ease-out}}
.profile{{display:flex;flex-wrap:wrap;gap:14px;align-items:end;padding:24px 0;border-bottom:1px solid var(--line)}} label{{display:grid;gap:6px;color:var(--muted);font-size:.86rem}} select,input,textarea{{min-height:44px;padding:9px 11px}} textarea{{width:100%;min-height:90px;resize:vertical}}
.source{{padding:30px 0;border-bottom:1px solid var(--line)}} .source-head{{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-start;justify-content:space-between;margin-bottom:18px}} .meta{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.76rem;color:var(--muted);overflow-wrap:anywhere;max-width:68ch}}
.quality{{display:flex;flex-wrap:wrap;gap:7px;margin-top:10px}} .tag{{display:inline-flex;align-items:center;min-height:26px;padding:3px 8px;border-radius:99px;background:var(--raised);color:var(--muted);font-size:.78rem}} .tag.good{{color:var(--cyan)}} .tag.warn{{color:#ffd09b}}
video{{display:block;width:100%;max-height:560px;background:#000;border-radius:var(--radius);margin-bottom:18px}}
.candidates{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}} .candidate{{padding:14px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius)}} .candidate.selected{{border-color:var(--lime)}} .candidate-head{{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:10px}} .candidate button{{background:var(--lime);color:#07100b;border-color:var(--lime)}} .filmstrip{{display:flex;gap:5px;overflow-x:auto;padding:4px 0 8px;scroll-snap-type:x proximity}} .filmstrip button{{padding:0;border:0;background:none;min-height:0;scroll-snap-align:start}} .filmstrip img{{display:block;width:112px;aspect-ratio:16/9;object-fit:cover;border-radius:6px}} .filmstrip button:focus-visible img{{outline:3px solid var(--lime)}}
.editor{{display:none;margin-top:22px;padding-top:20px;border-top:1px solid var(--line)}} .editor.visible{{display:block}} .editor-grid{{display:grid;grid-template-columns:minmax(280px,.85fr) minmax(360px,1.15fr);gap:26px}} table{{width:100%;border-collapse:collapse}} th{{text-align:left;color:var(--muted);font-size:.78rem;font-weight:600}} th,td{{padding:9px 7px;border-bottom:1px solid var(--line)}} td input[type=number],td select{{width:100%}} .visible-control{{display:flex;gap:8px;align-items:center;color:var(--ink)}} .visible-control input{{min-height:0;width:18px;height:18px;accent-color:var(--lime)}} .decision{{display:grid;gap:14px}} .decision label{{width:100%}} .decision select{{width:100%}}
.rubric{{border-top:1px solid var(--line);padding:10px 0}} .rubric summary{{cursor:pointer;font-weight:650}} .rubric p{{margin:7px 0;color:var(--muted);font-size:.84rem}} .scale{{display:flex;flex-wrap:wrap;gap:6px;margin:10px 0 4px}} .scale .tag strong{{color:var(--ink)}}
.actions{{display:flex;flex-wrap:wrap;gap:10px;margin-top:24px}} .primary{{background:var(--lime);color:#07100b;border-color:var(--lime)}} .secondary{{background:var(--raised)}} .message{{min-height:24px;margin-top:12px;color:var(--muted)}} .message.error{{color:var(--danger)}} .message.success{{color:var(--lime)}}
.disclosure{{padding-top:24px;color:var(--muted);font-size:.86rem}}
@media(max-width:800px){{header{{grid-template-columns:1fr}} .candidates,.editor-grid{{grid-template-columns:1fr}} .shell{{padding-inline:14px}} .progress{{margin-inline:-14px;padding-inline:14px}} h1{{font-size:2rem}}}}
@media(prefers-reduced-motion:reduce){{html{{scroll-behavior:auto}} .progress-bar i{{transition:none}}}}
</style>
</head>
<body><main class="shell">
<header><div><h1>Turn two source videos into honest calibration records.</h1><p class="lede">Choose one serve from each original, verify the ten phase anchors, and rate only technique that this rear view actually shows. Nothing is submitted automatically.</p></div><div class="status"><strong>Local calibration only.</strong><br>These two videos belong to one participant. They are not independent release evidence, and the page cannot grant training consent.</div></header>
<div class="progress"><strong id="progress-label">0 of {source_count} reviewed</strong><div class="progress-bar" aria-hidden="true"><i id="progress-fill"></i></div></div>
<section class="profile" aria-label="Participant profile">
<label>Dominant hand<select id="hand"><option value="">Select</option><option value="right">Right</option><option value="left">Left</option></select></label>
<label>Skill level<select id="skill"><option value="">Select</option><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option><option value="advanced">Advanced</option><option value="competitive">Competitive</option></select></label>
<span class="muted">Participant: <strong>{html.escape(manifest['participantPseudonym'])}</strong> · View: rear three-quarter</span>
</section>
<div id="sources"></div>
<div class="actions"><button class="secondary" id="save">Save draft in this browser</button><button class="primary" id="download">Download reviewed JSON</button></div>
<p id="message" class="message" role="status"></p>
<p class="disclosure">Apple Vision pose extraction must still be rerun on iPhone because the restricted local macOS runtime could not initialize the body-pose request. Downloaded decisions remain bound to each original SHA-256. Working H.264 media is for browser review only.</p>
</main>
<script id="seed" type="application/json">{data}</script>
<script>
const seed=JSON.parse(document.getElementById('seed').textContent);
const phases=seed.phases,techniques=seed.techniques,key='serveai-local-calibration-v1';
let state={{participantPseudonym:seed.manifest.participantPseudonym,dominantHand:'',skillLevel:'',sources:{{}}}};
const $=id=>document.getElementById(id),esc=s=>String(s).replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
function initialPhaseTimes(c){{const contact=c.contactEstimate,start=c.startTime;const points=[start+.3,start+.9,contact-1.05,contact-.7,contact-.48,contact-.34,contact-.2,contact,contact+.14,contact+.52];return Object.fromEntries(phases.map((p,i)=>[p.id,+Math.max(start,Math.min(c.endTime,points[i])).toFixed(2)]));}}
function ensureSource(source){{if(!state.sources[source.filename])state.sources[source.filename]={{sourceVideoSHA256:source.sha256,selectedCandidateID:'',phaseAnchors:{{}},techniqueRatings:Object.fromEntries(techniques.map(t=>[t.id,{{isVisible:true,rating:''}}])),topPriority:'',notes:'',reviewed:false}};return state.sources[source.filename];}}
function render(){{$('hand').value=state.dominantHand;$('skill').value=state.skillLevel;$('sources').innerHTML=seed.manifest.sources.map(source=>renderSource(source)).join('');bind();updateProgress();}}
function renderSource(source){{const s=ensureSource(source),selected=source.candidates.find(c=>c.id===s.selectedCandidateID);return `<section class="source" data-source="${{esc(source.filename)}}"><div class="source-head"><div><h2>${{esc(source.filename)}}</h2><div class="quality">${{source.qualityAssessment.strengths.map(x=>`<span class="tag good">${{esc(x)}}</span>`).join('')}}${{source.qualityAssessment.limitations.map(x=>`<span class="tag warn">${{esc(x)}}</span>`).join('')}}</div></div><div class="meta">${{source.width}}×${{source.height}} · ${{source.nominalFrameRate.toFixed(2)}} fps · ${{source.duration.toFixed(2)}}s<br>SHA-256 ${{source.sha256}}</div></div><video controls preload="metadata" src="${{esc(source.video)}}"></video><div class="candidates">${{source.candidates.map(c=>renderCandidate(source,c,s.selectedCandidateID)).join('')}}</div>${{renderEditor(source,s,selected)}}</section>`;}}
function renderCandidate(source,c,selectedID){{const selected=c.id===selectedID;return `<div class="candidate ${{selected?'selected':''}}"><div class="candidate-head"><div><strong>${{esc(c.label)}}</strong><div class="muted">${{c.startTime.toFixed(1)}}–${{c.endTime.toFixed(1)}}s · contact estimate ${{c.contactEstimate.toFixed(1)}}s</div></div><button data-select="${{c.id}}">${{selected?'Selected':'Use this serve'}}</button></div><div class="filmstrip">${{c.frames.map((frame,i)=>`<button data-seek="${{(c.startTime+i/5).toFixed(2)}}"><img loading="lazy" src="${{esc(frame)}}" alt="${{esc(c.label)}} at ${{(c.startTime+i/5).toFixed(1)}} seconds"></button>`).join('')}}</div></div>`;}}
function renderEditor(source,s,c){{if(!c)return '<div class="editor"></div>';if(!Object.keys(s.phaseAnchors).length)s.phaseAnchors=initialPhaseTimes(c);const phaseRows=phases.map(p=>`<tr><td>${{esc(p.label)}}</td><td><input data-phase="${{p.id}}" type="number" min="${{c.startTime}}" max="${{c.endTime}}" step=".01" value="${{s.phaseAnchors[p.id]??''}}" aria-label="${{esc(p.label)}} time"></td></tr>`).join('');const techniqueRows=techniques.map(t=>{{const v=s.techniqueRatings[t.id];return `<tr><td>${{esc(t.label)}}<details class="rubric"><summary>Observation rule</summary><p>${{esc(t.observe)}}</p><p><strong>Must see:</strong> ${{esc(t.requiredVisibility)}}</p><p><strong>Do not infer:</strong> ${{esc(t.doNotInfer)}}</p></details></td><td><label class="visible-control"><input data-visible="${{t.id}}" type="checkbox" ${{v.isVisible?'checked':''}}>Visible</label></td><td><select data-rating="${{t.id}}" ${{v.isVisible?'':'disabled'}} aria-label="${{esc(t.label)}} rating"><option value="">Rate</option>${{seed.ratingScale.map(x=>`<option value="${{x.rating}}" ${{String(v.rating)===String(x.rating)?'selected':''}}>${{x.rating}} · ${{esc(x.anchor)}}</option>`).join('')}}</select></td></tr>`}}).join('');const scale=seed.ratingScale.map(x=>`<span class="tag"><strong>${{x.rating}}</strong>&nbsp; ${{esc(x.anchor)}}</span>`).join('');return `<div class="editor visible"><div class="editor-grid"><section><h3>Phase anchor times</h3><p class="muted">Estimates are starting points. Click a filmstrip frame to seek the video, then correct each time.</p><table><thead><tr><th>Phase</th><th>Seconds</th></tr></thead><tbody>${{phaseRows}}</tbody></table></section><section class="decision"><div><h3>Observable technique</h3><p class="muted">Uncheck anything this angle cannot establish. Do not give hidden technique a neutral score.</p><div class="scale">${{scale}}</div><table><thead><tr><th>Technique</th><th>Evidence</th><th>Rating</th></tr></thead><tbody>${{techniqueRows}}</tbody></table></div><label>Highest coaching priority<select data-priority><option value="">Select after rating</option>${{techniques.map(t=>`<option value="${{t.id}}" ${{s.topPriority===t.id?'selected':''}}>${{esc(t.label)}}</option>`).join('')}}</select></label><label>Reviewer notes<textarea data-notes placeholder="What is technically correct, uncertain, or missing?">${{esc(s.notes)}}</textarea></label><label class="visible-control"><input data-reviewed type="checkbox" ${{s.reviewed?'checked':''}}>I reviewed this selected serve</label></section></div></div>`;}}
function bind(){{document.querySelectorAll('[data-source]').forEach(section=>{{const source=seed.manifest.sources.find(x=>x.filename===section.dataset.source),s=ensureSource(source),video=section.querySelector('video');section.querySelectorAll('[data-select]').forEach(b=>b.onclick=()=>{{s.selectedCandidateID=b.dataset.select;s.phaseAnchors={{}};s.reviewed=false;render()}});section.querySelectorAll('[data-seek]').forEach(b=>b.onclick=()=>{{video.currentTime=+b.dataset.seek;video.play().catch(()=>{{}})}});section.querySelectorAll('[data-phase]').forEach(i=>i.oninput=()=>s.phaseAnchors[i.dataset.phase]=+i.value);section.querySelectorAll('[data-visible]').forEach(i=>i.onchange=()=>{{const v=s.techniqueRatings[i.dataset.visible];v.isVisible=i.checked;if(!i.checked)v.rating='';render()}});section.querySelectorAll('[data-rating]').forEach(i=>i.onchange=()=>s.techniqueRatings[i.dataset.rating].rating=i.value);const priority=section.querySelector('[data-priority]');if(priority)priority.onchange=()=>s.topPriority=priority.value;const notes=section.querySelector('[data-notes]');if(notes)notes.oninput=()=>s.notes=notes.value;const reviewed=section.querySelector('[data-reviewed]');if(reviewed)reviewed.onchange=()=>{{s.reviewed=reviewed.checked;updateProgress()}};}});}}
function updateProgress(){{const values=Object.values(state.sources),done=values.filter(x=>x.reviewed).length,total=seed.manifest.sources.length;$('progress-label').textContent=`${{done}} of ${{total}} reviewed`;$('progress-fill').style.width=`${{100*done/total}}%`;}}
function validationErrors(){{const errors=[];if(!state.dominantHand)errors.push('select dominant hand');if(!state.skillLevel)errors.push('select skill level');for(const source of seed.manifest.sources){{const s=ensureSource(source);if(!s.selectedCandidateID)errors.push(`${{source.filename}}: choose one serve`);if(!s.reviewed)errors.push(`${{source.filename}}: confirm review`);for(const t of techniques){{const v=s.techniqueRatings[t.id];if(v.isVisible&&!v.rating)errors.push(`${{source.filename}}: rate ${{t.label}} or mark it hidden`)}}if(!s.topPriority)errors.push(`${{source.filename}}: select priority`);else{{const visible=techniques.map(t=>[t.id,s.techniqueRatings[t.id]]).filter(([,v])=>v.isVisible&&v.rating).map(([id,v])=>[id,+v.rating]);if(visible.length){{const minimum=Math.min(...visible.map(([,rating])=>rating)),chosen=visible.find(([id])=>id===s.topPriority);if(!chosen||chosen[1]!==minimum)errors.push(`${{source.filename}}: priority must be a lowest-rated visible technique`)}}}}}}return errors;}}
function exportValue(){{
  return {{
    schemaVersion:1,
    purpose:'human-reviewed-local-calibration',
    createdAt:new Date().toISOString(),
    participantPseudonym:state.participantPseudonym,
    dominantHand:state.dominantHand,
    skillLevel:state.skillLevel,
    cameraAngle:'rear',
    consentStatus:'pending-signed-training-consent',
    poseEvidenceStatus:'pending-iPhone-extraction',
    sources:seed.manifest.sources.map(source=>{{
      const reviewed=state.sources[source.filename];
      return {{
        filename:source.filename,
        sourceVideoSHA256:source.sha256,
        ...reviewed,
        techniqueRatings:Object.fromEntries(techniques.map(t=>{{
          const value=reviewed.techniqueRatings[t.id];
          return [t.id,{{isVisible:value.isVisible,rating:value.isVisible&&value.rating?+value.rating:null}}];
        }}))
      }};
    }})
  }};
}}
$('hand').onchange=()=>state.dominantHand=$('hand').value;$('skill').onchange=()=>state.skillLevel=$('skill').value;$('save').onclick=()=>{{localStorage.setItem(key,JSON.stringify(state));show('Draft saved in this browser.','success')}};$('download').onclick=()=>{{const errors=validationErrors();if(errors.length){{show(errors.slice(0,4).join(' · ')+(errors.length>4?` · plus ${{errors.length-4}} more`:''),'error');return}}const blob=new Blob([JSON.stringify(exportValue(),null,2)],{{type:'application/json'}}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='serveai-participant-local-001-reviewed.json';a.click();URL.revokeObjectURL(a.href);show('Reviewed JSON downloaded. It still requires signed consent and iPhone pose evidence.','success')}};function show(text,type){{$('message').textContent=text;$('message').className=`message ${{type}}`;}}
try{{const stored=JSON.parse(localStorage.getItem(key));if(stored&&stored.participantPseudonym===state.participantPseudonym)state=stored}}catch{{}}render();
</script></body></html>"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(build_html(manifest, args.output))
    print(f"wrote calibration review to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
