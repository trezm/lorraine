"""Modal deployment for Lorraine's WhisperX transcription service.

Deploy with: modal deploy backend/modal_app.py
Required secrets:
- HF_TOKEN in a Modal secret named ``lorraine-secrets``.
- LORRAINE_API_KEY in a separate secret named ``lorraine-api-auth``.
"""

from __future__ import annotations

import base64
import hashlib
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
LONG_REQUEST_TIMEOUT_SECONDS = 60 * 60 * 2

app = modal.App(APP_NAME)
data_volume = modal.Volume.from_name("lorraine-data", create_if_missing=True)
model_cache = modal.Volume.from_name("lorraine-model-cache", create_if_missing=True)
secret_name = os.environ.get("LORRAINE_MODAL_SECRET", "lorraine-secrets")
api_secret_name = os.environ.get("LORRAINE_MODAL_API_SECRET", "lorraine-api-auth")
transcription_secrets = [modal.Secret.from_name(secret_name)]
api_secrets = [
    *transcription_secrets,
    modal.Secret.from_name(api_secret_name),
]

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
    enriched_threshold: float,
    required_margin: float,
) -> tuple[str | None, float | None]:
    import numpy as np

    if not embedding or not profiles:
        return None, None
    target = np.asarray(_normalise(embedding), dtype=np.float32)
    scored: list[tuple[str, float, int]] = []
    for profile in profiles:
        stored_samples = profile.get("embeddings") or []
        if not stored_samples and profile.get("embedding"):
            stored_samples = [profile["embedding"]]
        candidates = [
            np.asarray(_normalise(values), dtype=np.float32)
            for values in stored_samples
            if len(values) == len(target)
        ]
        if not candidates:
            continue
        centroid = np.asarray(
            _normalise(np.mean(candidates, axis=0).tolist()),
            dtype=np.float32,
        )
        centroid_score = float(np.dot(target, centroid))
        sample_score = max(float(np.dot(target, candidate)) for candidate in candidates)
        score = max(centroid_score, sample_score)
        scored.append((str(profile["id"]), score, len(candidates)))
    if not scored:
        return None, None
    scored.sort(key=lambda item: item[1], reverse=True)
    best_id, best_score, enrollment_count = scored[0]
    runner_up_score = scored[1][1] if len(scored) > 1 else None
    margin = float("inf") if runner_up_score is None else best_score - runner_up_score
    accepted = best_score >= threshold or (
        enrollment_count >= 2
        and best_score >= enriched_threshold
        and margin >= required_margin
    )
    return (best_id if accepted else None), best_score


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
    timeout=LONG_REQUEST_TIMEOUT_SECONDS,
    volumes={"/data": data_volume, CACHE_ROOT: model_cache},
    secrets=transcription_secrets,
)
def transcribe(
    job_id: str,
    known_profiles: list[dict[str, Any]],
    threshold: float,
    enriched_threshold: float,
    required_margin: float,
) -> None:
    """Transcribe one persisted input and store a JSON result for polling."""
    import gc

    import torch
    import whisperx
    from whisperx.diarize import DiarizationPipeline

    try:
        data_volume.reload()
        directory = DATA_ROOT / job_id
        audio_path = next(directory.glob("input.*"))
        _write_status(
            job_id,
            {"status": "processing", "stage": "starting", "progress": 0.12},
        )
        data_volume.commit()

        device = "cuda"
        audio = whisperx.load_audio(str(audio_path))
        _write_status(
            job_id,
            {"status": "processing", "stage": "transcribing", "progress": 0.2},
        )
        data_volume.commit()
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

        _write_status(
            job_id,
            {"status": "processing", "stage": "aligning", "progress": 0.62},
        )
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

        _write_status(
            job_id,
            {"status": "processing", "stage": "diarizing", "progress": 0.76},
        )
        data_volume.commit()
        hf_token = os.environ.get("HF_TOKEN")
        if not hf_token:
            raise RuntimeError(
                "HF_TOKEN is missing from the lorraine-secrets Modal secret"
            )
        diarizer = DiarizationPipeline(
            token=hf_token,
            device=device,
            cache_dir=f"{CACHE_ROOT}/huggingface",
        )
        diarization, embeddings = diarizer(audio, return_embeddings=True)
        result = whisperx.assign_word_speakers(
            diarization, result, speaker_embeddings=embeddings, fill_nearest=True
        )

        _write_status(
            job_id,
            {"status": "processing", "stage": "voices", "progress": 0.88},
        )
        data_volume.commit()
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
            match_id, confidence = _best_match(
                embedding,
                known_profiles,
                threshold,
                enriched_threshold,
                required_margin,
            )
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
            {"status": "processing", "stage": "finalizing", "progress": 0.96},
        )
        data_volume.commit()
        _write_status(
            job_id,
            {
                "status": "complete",
                "stage": "complete",
                "progress": 1.0,
                "language": result.get("language", "unknown"),
                "segments": segments,
                "speakers": speaker_results,
            },
        )
        audio_path.unlink(missing_ok=True)
        data_volume.commit()
        model_cache.commit()
    except Exception as error:
        _write_status(
            job_id,
            {"status": "failed", "stage": "failed", "error": str(error)},
        )
        data_volume.commit()
        raise


@app.function(
    image=web_image,
    # Large meeting uploads can keep this request open for several minutes.
    timeout=LONG_REQUEST_TIMEOUT_SECONDS,
    volumes={"/data": data_volume},
    secrets=api_secrets,
)
@modal.asgi_app()
def api():
    from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile

    # With postponed annotations, FastAPI resolves UploadFile from module globals.
    globals()["UploadFile"] = UploadFile
    globals()["Request"] = Request

    web = FastAPI(title="Lorraine transcription API", version="1.0")

    def authorize(authorization: str | None) -> None:
        expected = os.environ.get("LORRAINE_API_KEY", "")
        if not expected:
            raise HTTPException(
                status_code=503,
                detail="API authentication is not configured",
            )
        supplied = (authorization or "").removeprefix("Bearer ")
        if not hmac.compare_digest(supplied, expected):
            raise HTTPException(status_code=401, detail="Invalid API key")

    @web.get("/health")
    async def health():
        return {"status": "ok"}

    def job_directory(job_id: str) -> Path:
        try:
            uuid.UUID(job_id)
        except ValueError as error:
            raise HTTPException(status_code=404, detail="Job not found") from error
        return DATA_ROOT / job_id

    @web.post("/uploads", status_code=201)
    async def create_upload(
        meeting_id: str = Form(...),
        filename: str = Form(...),
        known_profiles: str = Form("[]"),
        match_threshold: float = Form(0.75),
        enriched_match_threshold: float = Form(0.60),
        match_margin: float = Form(0.25),
        total_bytes: int = Form(...),
        chunk_count: int = Form(...),
        audio_sha256: str = Form(...),
        authorization: str | None = Header(None),
    ):
        authorize(authorization)
        del meeting_id
        profiles = json.loads(known_profiles)
        if not isinstance(profiles, list):
            raise HTTPException(
                status_code=400, detail="known_profiles must be a JSON list"
            )
        if total_bytes <= 0 or chunk_count <= 0 or chunk_count > 10_000:
            raise HTTPException(status_code=400, detail="Invalid upload size")
        if len(audio_sha256) != 64:
            raise HTTPException(status_code=400, detail="Invalid audio checksum")
        suffix = Path(filename).suffix.lower()
        if suffix not in {".m4a", ".mp3", ".wav", ".mp4", ".webm", ".ogg"}:
            suffix = ".m4a"
        job_id = str(uuid.uuid4())
        directory = DATA_ROOT / job_id
        directory.mkdir(parents=True, exist_ok=True)
        metadata = {
            "suffix": suffix,
            "profiles": profiles,
            "match_threshold": max(0.0, min(1.0, match_threshold)),
            "enriched_match_threshold": max(0.0, min(1.0, enriched_match_threshold)),
            "match_margin": max(0.0, min(1.0, match_margin)),
            "total_bytes": total_bytes,
            "chunk_count": chunk_count,
            "audio_sha256": audio_sha256,
        }
        (directory / "upload.json").write_text(json.dumps(metadata), encoding="utf-8")
        _write_status(
            job_id,
            {"status": "uploading", "stage": "receiving", "progress": 0.02},
        )
        data_volume.commit()
        return {"job_id": job_id, "status": "uploading"}

    @web.put("/uploads/{job_id}/chunks/{index}")
    async def put_upload_chunk(
        job_id: str,
        index: int,
        request: Request,
        x_chunk_sha256: str = Header(...),
        authorization: str | None = Header(None),
    ):
        authorize(authorization)
        directory = job_directory(job_id)
        data_volume.reload()
        metadata_path = directory / "upload.json"
        if not metadata_path.exists():
            raise HTTPException(status_code=404, detail="Upload not found")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        chunk_count = int(metadata["chunk_count"])
        if index < 0 or index >= chunk_count:
            raise HTTPException(status_code=400, detail="Invalid chunk index")
        content = await request.body()
        if not content or len(content) > 8 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="Chunk must be at most 8 MB")
        actual_hash = hashlib.sha256(content).hexdigest()
        if not hmac.compare_digest(actual_hash, x_chunk_sha256):
            raise HTTPException(status_code=409, detail="Chunk checksum mismatch")
        destination = directory / f"chunk-{index:05d}.part"
        temporary = directory / f"chunk-{index:05d}.tmp"
        temporary.write_bytes(content)
        temporary.replace(destination)
        received = len(list(directory.glob("chunk-*.part")))
        _write_status(
            job_id,
            {
                "status": "uploading",
                "stage": "receiving",
                "progress": 0.02 + (0.08 * received / chunk_count),
            },
        )
        data_volume.commit()
        return {"received": index, "chunks_received": received}

    @web.post("/uploads/{job_id}/complete", status_code=202)
    async def complete_upload(
        job_id: str,
        authorization: str | None = Header(None),
    ):
        authorize(authorization)
        directory = job_directory(job_id)
        data_volume.reload()
        metadata_path = directory / "upload.json"
        if not metadata_path.exists():
            status_path = directory / "status.json"
            if status_path.exists():
                return {"job_id": job_id, "status": "processing"}
            raise HTTPException(status_code=404, detail="Upload not found")
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        chunks = [
            directory / f"chunk-{index:05d}.part"
            for index in range(int(metadata["chunk_count"]))
        ]
        if any(not chunk.exists() for chunk in chunks):
            raise HTTPException(status_code=409, detail="Upload is missing chunks")
        destination = directory / f"input{metadata['suffix']}"
        digest = hashlib.sha256()
        written = 0
        with destination.open("wb") as output:
            for chunk in chunks:
                with chunk.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        digest.update(block)
                        written += len(block)
                        output.write(block)
        if written != int(metadata["total_bytes"]) or not hmac.compare_digest(
            digest.hexdigest(), str(metadata["audio_sha256"])
        ):
            destination.unlink(missing_ok=True)
            raise HTTPException(
                status_code=409, detail="Completed upload checksum mismatch"
            )
        _write_status(
            job_id,
            {"status": "processing", "stage": "queued", "progress": 0.1},
        )
        data_volume.commit()
        transcribe.spawn(
            job_id,
            metadata["profiles"],
            float(metadata["match_threshold"]),
            float(metadata.get("enriched_match_threshold", 0.60)),
            float(metadata.get("match_margin", 0.25)),
        )
        for chunk in chunks:
            chunk.unlink(missing_ok=True)
        metadata_path.unlink(missing_ok=True)
        data_volume.commit()
        return {"job_id": job_id, "status": "processing"}

    @web.post("/jobs", status_code=202)
    async def create_job(
        audio: UploadFile = File(...),
        meeting_id: str = Form(...),
        known_profiles: str = Form("[]"),
        match_threshold: float = Form(0.75),
        enriched_match_threshold: float = Form(0.60),
        match_margin: float = Form(0.25),
        authorization: str | None = Header(None),
    ):
        authorize(authorization)
        del meeting_id  # The client owns meeting metadata; Modal only needs a job ID.
        profiles = json.loads(known_profiles)
        if not isinstance(profiles, list):
            raise HTTPException(
                status_code=400, detail="known_profiles must be a JSON list"
            )
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
        _write_status(
            job_id,
            {"status": "processing", "stage": "queued", "progress": 0.1},
        )
        data_volume.commit()
        transcribe.spawn(
            job_id,
            profiles,
            max(0.0, min(1.0, match_threshold)),
            max(0.0, min(1.0, enriched_match_threshold)),
            max(0.0, min(1.0, match_margin)),
        )
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
