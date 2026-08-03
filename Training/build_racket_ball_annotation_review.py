#!/usr/bin/env python3
"""Build a local, source-bound racket and ball keypoint review."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REVIEW = Path.home() / "Downloads/serveai-participant-local-001-reviewed.json"
DEFAULT_VIDEO_DIRECTORY = Path.home() / "Downloads"
DEFAULT_OUTPUT = ROOT / "outputs/racket-ball-label-review"

PHASE_SAMPLES = {
    "racketDrop": (-0.12, -0.06, 0.0, 0.06),
    "upwardAcceleration": (-0.06, 0.0, 0.06),
    "contactPosition": (-0.08, -0.04, 0.0, 0.04, 0.08),
    "pronation": (0.0, 0.06, 0.12),
}

KEYPOINTS = (
    ("handleButt", "Handle butt", "#46d5ff", "End of the racket grip nearest the hand."),
    ("racketThroat", "Racket throat", "#c6ff3d", "Center of the V-junction above the handle."),
    ("hoopTop", "Hoop top", "#f3f5e8", "Topmost point of the hoop, opposite the handle."),
    ("hoopLeft", "Hoop left", "#ff8a3d", "Left edge of the hoop as seen in this frame."),
    ("hoopRight", "Hoop right", "#ff3d9a", "Right edge of the hoop as seen in this frame."),
    ("ballCenter", "Ball center", "#ffd166", "Visible center of the tennis ball."),
)


class BuildError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def planned_samples(review: dict) -> list[dict]:
    samples: list[dict] = []
    for source_index, source in enumerate(review.get("sources", [])):
        anchors = source.get("phaseAnchors", {})
        for phase, offsets in PHASE_SAMPLES.items():
            if phase not in anchors:
                raise BuildError(f"{source.get('filename', 'source')} is missing {phase}")
            anchor = float(anchors[phase])
            for offset_index, offset in enumerate(offsets):
                timestamp = round(max(0.0, anchor + offset), 3)
                samples.append({
                    "id": f"source-{source_index + 1}-{phase}-{offset_index + 1}",
                    "sourceIndex": source_index,
                    "sourceFilename": source["filename"],
                    "sourceVideoSHA256": source["sourceVideoSHA256"],
                    "phaseHint": phase,
                    "phaseAnchorSeconds": anchor,
                    "offsetSeconds": offset,
                    "timestampSeconds": timestamp,
                })
    return samples


def verify_sources(review: dict, video_directory: Path) -> dict[str, Path]:
    resolved: dict[str, Path] = {}
    for source in review.get("sources", []):
        filename = source["filename"]
        path = (video_directory / filename).resolve()
        if not path.is_file():
            raise BuildError(f"source video not found: {path}")
        if sha256_file(path) != source["sourceVideoSHA256"]:
            raise BuildError(f"source hash mismatch for {filename}")
        resolved[filename] = path
    return resolved


def extract_frame(video: Path, timestamp: float, output: Path) -> None:
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", f"{timestamp:.3f}", "-i", str(video), "-frames:v", "1",
        "-vf", "scale='min(1600,iw)':-2", "-q:v", "2", str(output),
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode or not output.is_file():
        detail = completed.stderr.strip() or "ffmpeg did not create a frame"
        raise BuildError(f"frame extraction failed at {timestamp:.3f}s: {detail}")


def materialize(review: dict, video_directory: Path, output: Path) -> dict:
    if not shutil.which("ffmpeg"):
        raise BuildError("ffmpeg is required to extract review frames")
    sources = verify_sources(review, video_directory)
    frames_directory = output / "frames"
    frames_directory.mkdir(parents=True, exist_ok=True)
    samples = planned_samples(review)
    for sample in samples:
        frame_name = f"{sample['id']}.jpg"
        frame_path = frames_directory / frame_name
        extract_frame(sources[sample["sourceFilename"]], sample["timestampSeconds"], frame_path)
        sample["framePath"] = f"frames/{frame_name}"
        sample["frameSHA256"] = sha256_file(frame_path)
    manifest = {
        "schemaVersion": 1,
        "purpose": "local-racket-ball-keypoint-labeling-pilot",
        "releaseEligible": False,
        "participantPseudonym": review.get("participantPseudonym"),
        "cameraAngle": review.get("cameraAngle"),
        "dominantHand": review.get("dominantHand"),
        "skillLevel": review.get("skillLevel"),
        "sourceReviewCreatedAt": review.get("createdAt"),
        "keypoints": [
            {"id": key, "label": label, "color": color, "instruction": instruction}
            for key, label, color, instruction in KEYPOINTS
        ],
        "samples": samples,
        "limitations": [
            "These labels come from one participant and cannot establish new-player accuracy.",
            "Two-dimensional racket keypoints do not directly measure three-dimensional forearm pronation.",
            "Phase hints come from the participant's earlier manual review and are not independent ground truth.",
        ],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def build_html(manifest: dict) -> str:
    data = json.dumps(manifest, separators=(",", ":")).replace("</", "<\\/")
    return LABEL_PAGE.replace("__SERVEAI_SEED__", data)


LABEL_PAGE = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ServeAI · Racket + ball label lab</title>
<style>
:root{--court:#08150f;--well:#0c1f16;--surface:#12271c;--raised:#183326;--chalk:#f3f5e8;--muted:#b8c6bb;--faint:#829087;--line:#315040;--lime:#c6ff3d;--orange:#ff8a3d;--focus:#f3f5e8;--z-sticky:20;color-scheme:dark}
*{box-sizing:border-box}html{height:100%}body{min-height:100%;margin:0;background:var(--court);color:var(--chalk);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}button,select{font:inherit;min-height:44px;border:1px solid var(--line);border-radius:10px;background:var(--surface);color:var(--chalk)}button{padding:9px 13px;cursor:pointer;font-weight:700;touch-action:manipulation;transition:background-color .18s ease-out,color .18s ease-out,opacity .18s ease-out}button:hover{background:var(--raised)}button:active{opacity:.78}button:focus-visible,select:focus-visible,.canvas-wrap:focus-visible{outline:3px solid var(--focus);outline-offset:3px}.skip{position:fixed;left:12px;top:-60px;z-index:50;background:var(--chalk);color:var(--court);padding:10px 14px;border-radius:8px}.skip:focus{top:12px}
.app{min-height:100dvh;display:grid;grid-template-rows:auto 1fr auto}.topbar{position:sticky;top:0;z-index:var(--z-sticky);display:grid;grid-template-columns:minmax(280px,1fr) minmax(260px,420px);gap:24px;align-items:center;padding:16px 24px;background:rgba(8,21,15,.97);border-bottom:1px solid var(--line)}h1{margin:0;font-size:1.35rem;letter-spacing:-.02em}.subtitle{margin:3px 0 0;color:var(--muted);font-size:.9rem}.progress-line{display:flex;gap:12px;align-items:center}.progress-line strong{font-variant-numeric:tabular-nums;white-space:nowrap}.track{height:8px;flex:1;background:var(--raised);border-radius:99px;overflow:hidden}.track i{display:block;height:100%;width:0;background:var(--lime);transition:width .2s ease-out}
.workspace{display:grid;grid-template-columns:minmax(250px,320px) minmax(0,1fr) minmax(270px,340px);min-height:0}.rail,.inspector{padding:18px;overflow:auto;background:var(--well)}.rail{border-right:1px solid var(--line)}.inspector{border-left:1px solid var(--line)}.rail h2,.inspector h2{font-size:1rem;margin:0 0 12px}.rail-note,.helper{color:var(--muted);font-size:.86rem;margin:0 0 14px}.frame-list{display:grid;gap:6px}.frame-item{display:grid;grid-template-columns:54px 1fr auto;gap:10px;align-items:center;width:100%;padding:7px;text-align:left}.frame-item[aria-current=true]{border-color:var(--lime);background:#1a3320}.thumb{width:54px;aspect-ratio:4/3;object-fit:cover;border-radius:6px;background:#000}.frame-meta{min-width:0}.frame-meta strong,.frame-meta span{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.frame-meta span{color:var(--muted);font-size:.74rem}.state{width:10px;height:10px;border:2px solid var(--faint);border-radius:50%}.state.done{border-color:var(--lime);background:var(--lime)}
.stage{min-width:0;display:grid;grid-template-rows:auto minmax(420px,1fr);background:#020805}.stagebar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--line)}.stage-title strong,.stage-title span{display:block}.stage-title span{font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}.zoom{display:flex;gap:8px;align-items:center}.zoom output{min-width:48px;text-align:center;font-variant-numeric:tabular-nums}.canvas-wrap{min-height:420px;overflow:auto;display:grid;place-items:center;padding:20px;background:#020805}canvas{display:block;max-width:none;cursor:crosshair;background:#000;box-shadow:0 0 0 1px #263d31}
.keypoints{display:grid;gap:8px}.tool{display:grid;grid-template-columns:18px 1fr auto;gap:10px;align-items:center;width:100%;text-align:left;padding:10px}.tool[aria-pressed=true]{border-color:var(--lime);background:#1a3320}.swatch{width:14px;height:14px;border-radius:50%;background:var(--swatch);box-shadow:0 0 0 2px var(--court),0 0 0 3px var(--swatch)}.tool-copy strong,.tool-copy span{display:block}.tool-copy span{color:var(--muted);font-size:.76rem}.tool kbd{color:var(--muted)}.point-actions{display:flex;gap:8px;margin:10px 0 18px}.point-actions button{flex:1}.summary{margin:18px 0;padding-top:16px;border-top:1px solid var(--line)}.summary-row{display:flex;justify-content:space-between;gap:10px;padding:5px 0;color:var(--muted);font-size:.84rem}.summary-row strong{color:var(--chalk)}.warning{padding:12px;background:#2b2012;color:#ffe0b4;border-radius:12px;font-size:.84rem}.warning strong{color:var(--orange)}
.footer{display:flex;gap:10px;align-items:center;padding:12px 18px;background:var(--court);border-top:1px solid var(--line)}.footer .message{flex:1;color:var(--muted);font-size:.85rem}.primary{background:var(--lime);border-color:var(--lime);color:var(--court)}.primary:hover{background:#d6ff70}.secondary{background:var(--raised)}.dialog{position:fixed;inset:auto 18px 18px auto;max-width:420px;padding:14px;background:var(--chalk);color:var(--court);border-radius:12px;transform:translateY(130%);transition:transform .2s ease-out;z-index:40}.dialog.show{transform:translateY(0)}kbd{font:11px ui-monospace,SFMono-Regular,Menlo,monospace;border:1px solid var(--line);border-bottom-width:2px;border-radius:5px;padding:2px 5px;background:var(--court)}
@media(max-width:1050px){.workspace{grid-template-columns:240px minmax(0,1fr)}.inspector{grid-column:1/-1;border-left:0;border-top:1px solid var(--line);display:grid;grid-template-columns:1fr 1fr;gap:18px}.keypoints{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:720px){.topbar{position:static;grid-template-columns:1fr;padding:14px}.workspace{display:block}.rail{border-right:0;border-bottom:1px solid var(--line);max-height:260px}.stage{min-height:560px}.inspector{display:block}.keypoints{grid-template-columns:1fr}.footer{position:sticky;bottom:0;flex-wrap:wrap}.footer .message{flex-basis:100%}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition-duration:.01ms!important}}
</style></head><body><a class="skip" href="#annotation-stage">Skip to annotation stage</a><main class="app">
<header class="topbar"><div><h1>Racket + ball label lab</h1><p class="subtitle">Click only what is visible. Every decision remains local until you download it.</p></div><div class="progress-line" aria-label="Review progress"><strong id="progressText">0 / 0 frames</strong><div class="track" aria-hidden="true"><i id="progressFill"></i></div></div></header>
<section class="workspace"><aside class="rail" aria-label="Frames"><h2>Critical motion frames</h2><p class="rail-note">Racket drop through post-contact. Completed frames have a lime marker.</p><div class="frame-list" id="frameList"></div></aside>
<section class="stage" id="annotation-stage"><div class="stagebar"><div class="stage-title"><strong id="frameTitle">Loading frame</strong><span id="frameEvidence"></span></div><div class="zoom"><button id="zoomOut" aria-label="Zoom out">−</button><output id="zoomValue">100%</output><button id="zoomIn" aria-label="Zoom in">+</button><button id="fit">Fit</button></div></div><div class="canvas-wrap" id="canvasWrap" tabindex="0" aria-label="Annotation image. Select a keypoint and click its position."><canvas id="canvas"></canvas></div></section>
<aside class="inspector" aria-label="Annotation tools"><div><h2>Place visible points</h2><p class="helper">Keys <kbd>1</kbd>–<kbd>6</kbd> select a point. Click the image to place it. Re-click to correct it.</p><div class="keypoints" id="keypoints"></div><div class="point-actions"><button id="notVisible">Not visible <kbd>N</kbd></button><button id="clearPoint">Clear point</button></div></div><div><div class="summary"><div class="summary-row"><span>Selected tool</span><strong id="selectedTool">—</strong></div><div class="summary-row"><span>Visible labels</span><strong id="visibleCount">0 / 6</strong></div><div class="summary-row"><span>Frame status</span><strong id="frameStatus">In progress</strong></div></div><div class="warning"><strong>Research pilot.</strong> These two clips test the workflow. They cannot prove accuracy across players, and 2D points cannot directly measure 3D pronation.</div></div></aside></section>
<footer class="footer"><div class="message" id="message" role="status">Draft saves automatically in this browser.</div><button class="secondary" id="previous">Previous</button><button class="primary" id="finish">Finish frame</button><button class="secondary" id="next">Next</button><button class="secondary" id="download">Download labeled JSON</button></footer></main><div class="dialog" id="toast" role="status" aria-live="polite"></div>
<script id="seed" type="application/json">__SERVEAI_SEED__</script><script>
const manifest=JSON.parse(document.getElementById('seed').textContent),storageKey='serveai-racket-ball-labels-'+manifest.participantPseudonym+'-v1',$=id=>document.getElementById(id);let index=0,tool=manifest.keypoints[0].id,zoom=1,image=new Image(),baseWidth=0;let state={frames:Object.fromEntries(manifest.samples.map(s=>[s.id,{reviewed:false,points:Object.fromEntries(manifest.keypoints.map(k=>[k.id,{status:'unreviewed',x:null,y:null}]))}]))};try{const saved=JSON.parse(localStorage.getItem(storageKey));if(saved&&saved.frames)state=saved}catch{}
const sample=()=>manifest.samples[index],frame=()=>state.frames[sample().id],esc=value=>String(value).replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char])),phase=value=>value.replace(/([A-Z])/g,' $1').replace(/^./,x=>x.toUpperCase()),persist=()=>localStorage.setItem(storageKey,JSON.stringify(state));
function renderList(){$('frameList').innerHTML=manifest.samples.map((s,i)=>`<button class="frame-item" data-index="${i}" aria-current="${i===index}"><img class="thumb" src="${esc(s.framePath)}" alt=""><span class="frame-meta"><strong>${esc(phase(s.phaseHint))}</strong><span>${esc(s.sourceFilename)} · ${s.timestampSeconds.toFixed(3)}s</span></span><i class="state ${state.frames[s.id].reviewed?'done':''}" aria-label="${state.frames[s.id].reviewed?'Reviewed':'Not reviewed'}"></i></button>`).join('');document.querySelectorAll('[data-index]').forEach(b=>b.onclick=()=>loadFrame(+b.dataset.index))}
function renderTools(){$('keypoints').innerHTML=manifest.keypoints.map((p,i)=>{const v=frame().points[p.id],text=v.status==='visible'?'Placed':v.status==='notVisible'?'Not visible':'Not reviewed';return `<button class="tool" data-tool="${p.id}" aria-pressed="${tool===p.id}" style="--swatch:${p.color}"><i class="swatch" aria-hidden="true"></i><span class="tool-copy"><strong>${esc(p.label)}</strong><span>${text}</span></span><kbd>${i+1}</kbd></button>`}).join('');document.querySelectorAll('[data-tool]').forEach(b=>b.onclick=()=>selectTool(b.dataset.tool));updateSummary()}
function selectTool(id){tool=id;renderTools();$('canvasWrap').focus()}
function loadFrame(next){index=Math.max(0,Math.min(manifest.samples.length-1,next));image=new Image();image.onload=()=>fitCanvas();image.onerror=()=>show('Could not load this frame. Rebuild the review.');image.src=sample().framePath;$('frameTitle').textContent=`${phase(sample().phaseHint)} · ${sample().timestampSeconds.toFixed(3)} seconds`;$('frameEvidence').textContent=`${sample().sourceFilename} · frame SHA-256 ${sample().frameSHA256.slice(0,16)}…`;renderList();renderTools();updateProgress()}
function fitCanvas(){baseWidth=Math.min(image.naturalWidth,Math.max(280,$('canvasWrap').clientWidth-40));zoom=1;sizeCanvas()}function sizeCanvas(){const width=Math.round(baseWidth*zoom),canvas=$('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;canvas.style.width=width+'px';canvas.style.height=Math.round(width*image.naturalHeight/image.naturalWidth)+'px';$('zoomValue').value=Math.round(zoom*100)+'%';draw()}
function line(c,a,b,color){if(!a||!b)return;c.beginPath();c.moveTo(a.x*c.canvas.width,a.y*c.canvas.height);c.lineTo(b.x*c.canvas.width,b.y*c.canvas.height);c.strokeStyle=color;c.lineWidth=Math.max(3,c.canvas.width*.004);c.stroke()}
function draw(){if(!image.complete||!image.naturalWidth)return;const c=$('canvas').getContext('2d'),points=frame().points,get=id=>points[id]?.status==='visible'?points[id]:null;c.clearRect(0,0,c.canvas.width,c.canvas.height);c.drawImage(image,0,0);line(c,get('handleButt'),get('racketThroat'),'#46d5ff');line(c,get('racketThroat'),get('hoopTop'),'#c6ff3d');line(c,get('hoopLeft'),get('hoopRight'),'#ff8a3d');manifest.keypoints.forEach((p,i)=>{const v=get(p.id);if(!v)return;const x=v.x*c.canvas.width,y=v.y*c.canvas.height,r=Math.max(7,c.canvas.width*.007);c.beginPath();c.arc(x,y,r,0,Math.PI*2);c.fillStyle=p.color;c.fill();c.lineWidth=Math.max(2,c.canvas.width*.002);c.strokeStyle='#08150f';c.stroke();c.fillStyle='#08150f';c.font=`bold ${Math.max(11,c.canvas.width*.011)}px -apple-system`;c.textAlign='center';c.textBaseline='middle';c.fillText(String(i+1),x,y)})}
$('canvas').onclick=e=>{const rect=e.currentTarget.getBoundingClientRect(),v=frame().points[tool];v.status='visible';v.x=Math.max(0,Math.min(1,(e.clientX-rect.left)/rect.width));v.y=Math.max(0,Math.min(1,(e.clientY-rect.top)/rect.height));frame().reviewed=false;persist();draw();renderTools();renderList()};
function notVisible(){const v=frame().points[tool];Object.assign(v,{status:'notVisible',x:null,y:null});frame().reviewed=false;persist();draw();renderTools();renderList()}function clearPoint(){const v=frame().points[tool];Object.assign(v,{status:'unreviewed',x:null,y:null});frame().reviewed=false;persist();draw();renderTools();renderList()}
function finishFrame(){Object.values(frame().points).forEach(v=>{if(v.status==='unreviewed')v.status='notVisible'});frame().reviewed=true;persist();renderTools();renderList();updateProgress();show('Frame saved. Untouched points were marked not visible.');if(index<manifest.samples.length-1)loadFrame(index+1)}
function updateSummary(){const values=Object.values(frame().points),visible=values.filter(x=>x.status==='visible').length,definition=manifest.keypoints.find(x=>x.id===tool);$('selectedTool').textContent=definition?.label||'—';$('visibleCount').textContent=`${visible} / ${values.length}`;$('frameStatus').textContent=frame().reviewed?'Reviewed':'In progress'}function updateProgress(){const reviewed=Object.values(state.frames).filter(x=>x.reviewed).length,total=manifest.samples.length;$('progressText').textContent=`${reviewed} / ${total} frames`;$('progressFill').style.width=(100*reviewed/total)+'%'}
function show(text){$('message').textContent=text;const toast=$('toast');toast.textContent=text;toast.classList.add('show');clearTimeout(show.timer);show.timer=setTimeout(()=>toast.classList.remove('show'),3500)}function exportPayload(){return{schemaVersion:1,purpose:'human-reviewed-racket-ball-keypoint-pilot',createdAt:new Date().toISOString(),releaseEligible:false,participantPseudonym:manifest.participantPseudonym,cameraAngle:manifest.cameraAngle,dominantHand:manifest.dominantHand,skillLevel:manifest.skillLevel,keypointCoordinateSystem:'normalized-top-left-origin',limitations:manifest.limitations,frames:manifest.samples.map(s=>({sampleID:s.id,sourceFilename:s.sourceFilename,sourceVideoSHA256:s.sourceVideoSHA256,frameSHA256:s.frameSHA256,timestampSeconds:s.timestampSeconds,phaseHint:s.phaseHint,reviewed:state.frames[s.id].reviewed,points:state.frames[s.id].points}))}}
$('download').onclick=()=>{const incomplete=Object.values(state.frames).filter(x=>!x.reviewed).length;if(incomplete){show(`Review ${incomplete} remaining frame${incomplete===1?'':'s'} before downloading.`);return}const blob=new Blob([JSON.stringify(exportPayload(),null,2)+'\n'],{type:'application/json'}),link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=`serveai-${manifest.participantPseudonym}-racket-ball-labels.json`;link.click();setTimeout(()=>URL.revokeObjectURL(link.href),0);show('Labeled JSON downloaded. Keep the source videos with it.')};
$('notVisible').onclick=notVisible;$('clearPoint').onclick=clearPoint;$('finish').onclick=finishFrame;$('previous').onclick=()=>loadFrame(index-1);$('next').onclick=()=>loadFrame(index+1);$('zoomIn').onclick=()=>{zoom=Math.min(4,zoom+.25);sizeCanvas()};$('zoomOut').onclick=()=>{zoom=Math.max(.5,zoom-.25);sizeCanvas()};$('fit').onclick=fitCanvas;document.addEventListener('keydown',e=>{if(e.target.matches('select,input,textarea'))return;const n=Number(e.key);if(n>=1&&n<=manifest.keypoints.length){selectTool(manifest.keypoints[n-1].id);e.preventDefault()}else if(e.key.toLowerCase()==='n'){notVisible();e.preventDefault()}else if(e.key==='ArrowLeft'){loadFrame(index-1);e.preventDefault()}else if(e.key==='ArrowRight'){loadFrame(index+1);e.preventDefault()}else if(e.key==='Enter'){finishFrame();e.preventDefault()}});window.addEventListener('resize',()=>{if(image.complete&&image.naturalWidth)fitCanvas()});loadFrame(0);
</script></body></html>'''


def build(review_path: Path, video_directory: Path, output: Path) -> Path:
    review = json.loads(review_path.read_text())
    if review.get("purpose") != "human-reviewed-local-calibration":
        raise BuildError("review JSON has the wrong purpose")
    output.mkdir(parents=True, exist_ok=True)
    manifest = materialize(review, video_directory, output)
    page = output / "index.html"
    page.write_text(build_html(manifest))
    return page


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", type=Path, default=DEFAULT_REVIEW)
    parser.add_argument("--video-directory", type=Path, default=DEFAULT_VIDEO_DIRECTORY)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    try:
        page = build(args.review, args.video_directory, args.output)
    except (BuildError, OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(f"wrote racket and ball review to {page}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
