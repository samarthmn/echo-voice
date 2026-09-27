import asyncio
from contextlib import asynccontextmanager
from pathlib import Path
import secrets
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException
from fastapi.responses import JSONResponse
from .errors import ServiceError
from .schema import Transcribe, PrepareAudio, Diarize, Request as JobRequest
from .service import SpeechService


def create_app(root: Path, token: str, *, service=None):
    if len(token) < 32:
        raise ValueError("A bearer token of at least 32 characters is required")
    service = service or SpeechService(Path(root))

    @asynccontextmanager
    async def lifespan(app):
        yield
        await service.close()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.service = service

    @app.middleware("http")
    async def security(request, call_next):
        auth = request.headers.get("authorization", "").encode()
        if not secrets.compare_digest(auth, ("Bearer " + token).encode()):
            return JSONResponse(ServiceError("unauthorized", "Bearer authentication is required.", 401).payload(), status_code=401)
        if "origin" in request.headers or "sec-fetch-site" in request.headers:
            return JSONResponse(ServiceError("browser_forbidden", "Browser requests are not allowed.", 403).payload(), status_code=403)
        if request.method == "POST":
            try:
                length = int(request.headers.get("content-length", "0"))
            except ValueError:
                length = 32769
            if length < 0 or length > 32768 or "transfer-encoding" in request.headers:
                return JSONResponse(ServiceError("request_too_large", "Request exceeds the size limit.", 413).payload(), status_code=413)
        try:
            response = await call_next(request)
        except Exception:
            response = JSONResponse(ServiceError("processing_failed", "Local processing failed.", 500, True).payload(), status_code=500)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.exception_handler(ServiceError)
    async def service_error(request, error):
        return JSONResponse(error.payload(), status_code=error.status)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        return JSONResponse(ServiceError("invalid_request", "Request fields are invalid.", 422).payload(), status_code=422)

    @app.exception_handler(HTTPException)
    async def http_error(request, error):
        return JSONResponse(ServiceError("invalid_request", "The requested operation is unavailable.", error.status_code).payload(), status_code=error.status_code)

    async def execute(kind, body, request):
        task = asyncio.create_task(service.execute(kind, body.model_dump()))
        try:
            while not task.done():
                if await request.is_disconnected():
                    service.cancel(body.job_id)
                    raise ServiceError("cancelled", "Client disconnected.", 409, True)
                await asyncio.sleep(0.05)
            return await task
        except asyncio.CancelledError:
            service.cancel(body.job_id)
            raise ServiceError("cancelled", "Processing was cancelled.", 409, True) from None
        finally:
            if not task.done():
                task.cancel()

    @app.get("/echo/v1/health")
    async def health():
        return await asyncio.to_thread(service.health)

    @app.post("/echo/v1/transcribe")
    async def transcribe(body: Transcribe, request: Request):
        return await execute("asr", body, request)

    @app.post("/echo/v1/prepare-audio")
    async def prepare(body: PrepareAudio, request: Request):
        return await execute("aec", body, request)

    @app.post("/echo/v1/diarize")
    async def diarize(body: Diarize, request: Request):
        return await execute("diarization", body, request)

    @app.post("/echo/v1/cancel")
    async def cancel(body: JobRequest):
        return {"cancelled": service.cancel(body.job_id)}

    @app.post("/echo/v1/unload")
    async def unload():
        service.unload()
        return {"unloaded": True}

    return app
