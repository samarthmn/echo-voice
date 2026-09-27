from typing import Literal
from pydantic import BaseModel, ConfigDict, Field

class Request(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    job_id: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")

class VocabularyItem(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(min_length=1, max_length=128)
    spelling: str = Field(min_length=1, max_length=50)
    aliases: list[str] = Field(default_factory=list, max_length=100)
    enabled: bool = True
    important: bool = False

class Transcribe(Request):
    transcript_version_id: str | None = None
    configuration_id: str | None = None
    vocabulary: list[VocabularyItem] = Field(default_factory=list, max_length=500)
    fuzzy_vocabulary: bool = False
    model: Literal["whisper", "parakeet"] = "whisper"
    meeting_id: str
    window_id: str
    track: Literal["microphone", "remote", "cleanMicrophone"]
    relative_path: str
    start_time: float = Field(ge=0)
    language: Literal["en"] = "en"

class PrepareAudio(Request):
    meeting_id: str
    epoch_id: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")
    sequence: int = Field(ge=0)
    near_path: str
    far_path: str
    output_path: str
    reset: bool = False
    final: bool = False

class Diarize(Request):
    model: Literal["diarization", "community1"] = "diarization"
    meeting_id: str
    relative_path: str
    window_seconds: Literal[1800] | None = None
