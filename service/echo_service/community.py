"""Community-1: bounded PCM reads, explicit clustering cap, local model assets."""
import types
import numpy as np
import soundfile as sf
from .models import ModelAssets
from .audio import inspect_wav

class CommunityAdapter:
    def __init__(self, root):
        import torch
        from pyannote.audio import Pipeline
        torch.set_num_threads(2)
        torch.manual_seed(0)
        self.pipeline = Pipeline.from_pretrained(str(ModelAssets(root).require('community1')), token=False)
        self.pipeline.to(torch.device('cpu'))
        clustering = self.pipeline.clustering
        original = clustering.filter_embeddings
        def bounded_filter(this, *args, **kwargs):
            embeddings, chunks, speakers = original(*args, **kwargs)
            if len(embeddings) > 2000:
                selected = np.linspace(0, len(embeddings)-1, 2000, dtype=np.int64)
                return embeddings[selected], chunks[selected], speakers[selected]
            return embeddings, chunks, speakers
        clustering.filter_embeddings = types.MethodType(bounded_filter, clustering)

    def diarize(self, path, window_seconds):
        return diarize_bounded(self.pipeline, path, window_seconds)


def diarize_bounded(pipeline, path, window_seconds):
    import torch
    from pyannote.core import SlidingWindow, SlidingWindowFeature
    info = inspect_wav(path)
    inference = pipeline._segmentation
    duration, step = inference.duration, inference.step
    original_segmentation = pipeline.get_segmentations
    original_crop = pipeline._audio.crop
    result = []
    # Keep the canonical source on disk; tensors never span a whole meeting.
    with sf.SoundFile(path) as stream:
        for window_index, offset in enumerate(range(0, info.frames, (window_seconds * info.sample_rate) if window_seconds else info.frames)):
            length = min((window_seconds * info.sample_rate) if window_seconds else info.frames, info.frames-offset)
            def read(start, seconds):
                begin = max(0, int(round(start * info.sample_rate)))
                frames = max(1, int(round(seconds * info.sample_rate)))
                if frames > info.sample_rate * 30: raise ValueError('unbounded PCM request')
                audio = np.zeros((1, frames), dtype=np.float32)
                available = max(0, min(frames, length-begin))
                if available:
                    stream.seek(offset+begin)
                    audio[:, :available] = stream.read(available, dtype='float32', always_2d=True).T
                return torch.from_numpy(audio)
            def segmentation(this, file, hook=None):
                count = max(1, int(np.ceil(max(0, length/info.sample_rate-duration)/step))+1)
                blocks = []
                for index in range(count):
                    with torch.inference_mode():
                        values = inference.infer(read(index*step, duration)[None])
                    if isinstance(values, tuple): raise ValueError('unexpected multi-task segmentation')
                    blocks.append(values[0])
                return SlidingWindowFeature(np.stack(blocks), SlidingWindow(start=0, duration=duration, step=step))
            def crop(this, file, segment, **kwargs):
                return read(segment.start, segment.end-segment.start), info.sample_rate
            pipeline.get_segmentations = types.MethodType(segmentation, pipeline)
            pipeline._audio.crop = types.MethodType(crop, pipeline._audio)
            try:
                with torch.inference_mode(): output = pipeline({'audio': str(path), 'uri': 'local-recording'})
                annotation = getattr(output, "speaker_diarization", output)
                for segment, _, speaker in annotation.itertracks(yield_label=True):
                    start, end = max(0, segment.start), min(length/info.sample_rate, segment.end)
                    if end <= start: continue
                    prefix = f'window-{window_index:04d}:' if window_seconds else ''
                    result.append({'start': start + offset/info.sample_rate, 'end': end + offset/info.sample_rate, 'speaker': prefix + str(speaker)})
            finally:
                pipeline.get_segmentations = original_segmentation
                pipeline._audio.crop = original_crop
    return {'turns': result, 'partial': window_seconds is not None, 'bounded_pcm': True}
