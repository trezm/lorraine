"""Modal deployment for Lorraine's WhisperX transcription service.

Deploy with: modal deploy backend/modal_app.py
Required secret: HF_TOKEN in a Modal secret named ``lorraine-secrets``.
Optional secret: LORRAINE_API_KEY in the same secret.
"""

from __future__ import annotations

import base64
import hmac
import json
import os
import subprocess
import uuid
from pathlib import Path
from typing import Any

import modal


APP_NAME = "lorraine-transcription"
DATA_ROOT = Path("/data/jobs")
CACHE_ROOT = "/cache"

app = modal.App(APP_NAME)
data_volume = modal.Volume.from_name("lorraine-data", create_if_missing=True)
model_cache = modal.Volume.from_name("lorraine-model-cache", create_if_missing=True)
secret_name = os.environ.get("LORRAINE_MODAL_SECRET", "lorraine-secrets")
secrets = [modal.Secret.from_name(secret_name)]

web_image = modal.Image.debian_slim(python_version="3.12").pip_install(
    "fastapi[standard]==0.116.1",
    "python-multipart==0.0.20",
)

gpu_image = (
    modal.Image.from_registry(
        "nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04",
        add_python="3.11",
    )
    .apt_install("ffmpeg")
    .pip_install("whisperx==3.8.6")
)


def _write_status(job_id: str, payload: dict[str, Any]) -> None:
    directory = DATA_ROOT / job_id
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "status.tmp"
    temporary.write_text(json.dumps(payload), encoding="utf-8")
    temporary.replace(directory / "status.json")


def _normalise(vector: list[float]) -> list[float]:
    import numpy as np

    value = np.asarray(vector, dtype=np.float32)
    norm = float(np.linalg.norm(value))
    return (value / norm).tolist() if norm else value.tolist()


def _best_match(
    embedding: list[float],
    profiles: list[dict[str, Any]],
    threshold: float,
) -> tuple[str | None, float | None]:
    import numpy as np

    if not embedding or not profiles:
        return None, None
    target = np.asarray(_normalise(embedding), dtype=np.float32)
    best_id: str | None = None
    best_score = -1.0
    for profile in profiles:
        candidate_values = profile.get("embedding") or []
        if len(candidate_values) != len(target):
            continue
        candidate = np.asarray(_normalise(candidate_values), dtype=np.float32)
        score = float(np.dot(target, candidate))
        if score > best_score:
            best_id, best_score = str(profile["id"]), score
    if best_score < threshold:
        return None, best_score if best_score >= 0 else None
    return best_id, best_score


def _speaker_sample(
    audio_path: Path,
    diarization: Any,
    speaker: str,
    destination: Path,
) -> str | None:
    rows = diarization[diarization["speaker"] == speaker].copy()
    if rows.empty:
        return None
    rows["duration"] = rows["end"] - rows["start"]
    row = rows.sort_values("duration", ascending=False).iloc[0]
    duration = min(8.0, max(1.0, float(row["duration"])))
    command = [
        "ffmpeg",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        str(float(row["start"])),
        "-i",
        str(audio_path),
        "-t",
        str(duration),
        "-ac",
        "1",
        "-ar",
        "16000",
        str(destination),
    ]
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode != 0 or not destination.exists():
        return None
    return base64.b64encode(destination.read_bytes()).decode("ascii")


@app.function(
    image=gpu_image,
    gpu="A10G",
    timeout=60 * 30,
    volumes={"/data": data_volume, CACHE_ROOT: model_cache},
    secrets=secrets,
)
def transcribe(job_id: str, known_profiles: list[dict[str, Any]], threshold: float) -> None:
    """Transcribe one persisted input and store a JSON result for polling."""
    import gc

    import torch
    import whisperx
    from whisperx.diarize import DiarizationPipeline

    try:
        data_volume.reload()
        directory = DATA_ROOT / job_id
        audio_path = next(directory.glob("input.*"))
        _write_status(job_id, {"status": "processing", "stage": "transcribing"})
        data_volume.commit()

        device = "cuda"
        audio = whisperx.load_audio(str(audio_path))
        model = whisperx.load_model(
            "large-v3",
            device,
            compute_type="float16",
            download_root=f"{CACHE_ROOT}/whisperx",
        )
        result = model.transcribe(audio, batch_size=16)
        del model
        gc.collect()
        torch.cuda.empty_cache()

        _write_status(job_id, {"status": "processing", "stage": "aligning"})
        data_volume.commit()
        align_model, metadata = whisperx.load_align_model(
            language_code=result["language"], device=device
        )
        result = whisperx.align(
            result["segments"],
            align_model,
            metadata,
            audio,
            device,
            return_char_alignments=False,
        )
        del align_model
        gc.collect()
        torch.cuda.empty_cache()

        _write_status(job_id, {"status": "processing", "stage": "diarizing"})
        data_volume.commit()
        hf_token = os.environ.get("HF_TOKEN")
        if not hf_token:
            raise RuntimeError("HF_TOKEN is missing from the lorraine-secrets Modal secret")
        diarizer = DiarizationPipeline(
            token=hf_token,
            device=device,
            cache_dir=f"{CACHE_ROOT}/huggingface",
        )
        diarization, embeddings = diarizer(audio, return_embeddings=True)
        result = whisperx.assign_word_speakers(
            diarization, result, speaker_embeddings=embeddings, fill_nearest=True
        )

        segments = [
            {
                "start": float(segment.get("start", 0)),
                "end": float(segment.get("end", 0)),
                "speaker_id": segment.get("speaker", "SPEAKER_UNKNOWN"),
                "text": segment.get("text", "").strip(),
            }
            for segment in result.get("segments", [])
            if segment.get("text", "").strip()
        ]

        speaker_results = []
        for speaker in sorted(diarization["speaker"].unique().tolist()):
            embedding = _normalise((embeddings or {}).get(speaker, []))
            match_id, confidence = _best_match(embedding, known_profiles, threshold)
            sample_path = directory / f"sample-{speaker}.wav"
            sample = _speaker_sample(audio_path, diarization, speaker, sample_path)
            speaker_results.append(
                {
                    "id": speaker,
                    "embedding": embedding,
                    "sample_base64": sample,
                    "matched_profile_id": match_id,
                    "match_confidence": confidence,
                }
            )
            sample_path.unlink(missing_ok=True)

        _write_status(
            job_id,
            {
                "status": "complete",
                "language": result.get("language", "unknown"),
                "segments": segments,
                "speakers": speaker_results,
            },
        )
        audio_path.unlink(missing_ok=True)
        data_volume.commit()
        model_cache.commit()
    except Exception as error:
        _write_status(job_id, {"status": "failed", "error": str(error)})
        data_volume.commit()
        raise


@app.function(
    image=web_image,
    timeout=60 * 10,
    volumes={"/data": data_volume},
    secrets=secrets,
)
@modal.asgi_app()
def api():
    from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile

    # With postponed annotations, FastAPI resolves UploadFile from module globals.
    globals()["UploadFile"] = UploadFile

    web = FastAPI(title="Lorraine transcription API", version="1.0")

    def authorize(authorization: str | None) -> None:
        expected = os.environ.get("LORRAINE_API_KEY", "")
        if not expected:
            return
        supplied = (authorization or "").removeprefix("Bearer ")
        if not hmac.compare_digest(supplied, expected):
            raise HTTPException(status_code=401, detail="Invalid API key")

    @web.get("/health")
    async def health():
        return {"status": "ok"}

    @web.post("/jobs", status_code=202)
    async def create_job(
        audio: UploadFile = File(...),
        meeting_id: str = Form(...),
        known_profiles: str = Form("[]"),
        match_threshold: float = Form(0.72),
        authorization: str | None = Header(None),
    ):
        authorize(authorization)
        del meeting_id  # The client owns meeting metadata; Modal only needs a job ID.
        profiles = json.loads(known_profiles)
        if not isinstance(profiles, list):
            raise HTTPException(status_code=400, detail="known_profiles must be a JSON list")
        job_id = str(uuid.uuid4())
        suffix = Path(audio.filename or "recording.m4a").suffix.lower()
        if suffix not in {".m4a", ".mp3", ".wav", ".mp4", ".webm", ".ogg"}:
            suffix = ".m4a"
        directory = DATA_ROOT / job_id
        directory.mkdir(parents=True, exist_ok=True)
        destination = directory / f"input{suffix}"
        with destination.open("wb") as output:
            while chunk := await audio.read(1024 * 1024):
                output.write(chunk)
        _write_status(job_id, {"status": "processing", "stage": "queued"})
        data_volume.commit()
        transcribe.spawn(job_id, profiles, max(0.0, min(1.0, match_threshold)))
        return {"job_id": job_id, "status": "processing"}

    @web.get("/jobs/{job_id}")
    async def get_job(job_id: str, authorization: str | None = Header(None)):
        authorize(authorization)
        try:
            uuid.UUID(job_id)
        except ValueError as error:
            raise HTTPException(status_code=404, detail="Job not found") from error
        data_volume.reload()
        status_path = DATA_ROOT / job_id / "status.json"
        if not status_path.exists():
            raise HTTPException(status_code=404, detail="Job not found")
        return json.loads(status_path.read_text(encoding="utf-8"))

    return web
