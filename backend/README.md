# Lorraine Modal backend

This service accepts a meeting recording, returns immediately with a job ID, and runs WhisperX on an A10G GPU. The app polls until word-aligned transcription, anonymous speaker labels, voice embeddings, and short WAV samples are ready.

Uploads and GPU transcription calls allow up to two hours. The desktop client
polls an accepted job for up to three hours so queueing time does not consume the
worker's processing allowance.

The desktop creates a temporary 16 kHz mono AAC copy for transcription, keeps
the original recording untouched, and uploads the derivative in independently
checksummed 5 MB chunks. Modal verifies every chunk and the complete file before
starting WhisperX.

## Deploy

1. Create a Hugging Face read token and accept the terms for `pyannote/speaker-diarization-community-1`.
2. Install and authenticate Modal:

   ```sh
   python3 -m pip install -r backend/requirements-dev.txt
   modal setup
   ```

3. Store the required Hugging Face token:

   ```sh
   modal secret create lorraine-secrets HF_TOKEN=hf_...
   ```

   If `lorraine-secrets` does not exist, startup also recognizes existing secrets named `huggingface` or `huggingface-secret`.

4. Generate a long random API key and store it in the separate authentication secret:

   ```sh
   modal secret create lorraine-api-auth LORRAINE_API_KEY=choose-a-long-random-value
   ```

   The backend fails closed if this secret or key is missing. Enter the same value in Lorraine Settings; it is sent as a bearer token with every upload and job request.

5. Launch Lorraine. It automatically deploys this bundled backend with:

   ```sh
   modal deploy backend/modal_app.py
   ```

   You can also run that command manually while developing.

6. The endpoint URL is discovered and saved automatically. The unauthenticated health check exposes no meeting data; all upload and job endpoints require the API key.

The input recording is deleted from the Modal Volume after a successful run. Job results remain in `lorraine-data`; model weights are cached in `lorraine-model-cache` to reduce cold starts.
