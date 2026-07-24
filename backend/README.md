# Lorraine Modal backend

This service accepts a meeting recording, returns immediately with a job ID, and runs WhisperX on an A10G GPU. The app polls until word-aligned transcription, anonymous speaker labels, voice embeddings, and short WAV samples are ready.

## Deploy

1. Create a Hugging Face read token and accept the terms for `pyannote/speaker-diarization-community-1`.
2. Install and authenticate Modal:

   ```sh
   python3 -m pip install -r backend/requirements-dev.txt
   modal setup
   ```

3. Add the required token and an optional app API key:

   ```sh
   modal secret create lorraine-secrets HF_TOKEN=hf_... LORRAINE_API_KEY=choose-a-long-random-value
   ```

   If `lorraine-secrets` does not exist, startup also recognizes existing secrets named `huggingface` or `huggingface-secret`.

4. Launch Lorraine. It automatically deploys this bundled backend with:

   ```sh
   modal deploy backend/modal_app.py
   ```

   You can also run that command manually while developing.

5. If you set `LORRAINE_API_KEY`, enter the same value in Lorraine Settings. The endpoint URL is discovered and saved automatically.

The input recording is deleted from the Modal Volume after a successful run. Job results remain in `lorraine-data`; model weights are cached in `lorraine-model-cache` to reduce cold starts.
