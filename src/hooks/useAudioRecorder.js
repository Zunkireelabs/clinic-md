import { useState, useRef, useCallback, useEffect } from 'react';

// Safari has no webm support, so pick the first format the browser can record.
const PREFERRED_TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];

export const pickRecordingMimeType = (isSupported = (t) => window.MediaRecorder?.isTypeSupported?.(t)) =>
  PREFERRED_TYPES.find((t) => isSupported(t)) || '';

// Voice at 32 kbps is plenty for transcription and keeps long visits small: ~14 MB per hour.
export const AUDIO_BITS_PER_SECOND = 32000;
// Transcription accepts at most 25 MB. A recording is split into segments before it gets near that (each segment is a normal
// recording in the caller's queue), so a very long visit is never lost to a size limit.
export const MAX_SEGMENT_BYTES = 22 * 1024 * 1024;

/**
 * Microphone recording with pause/resume. `stop()` resolves with the finished { blob, mimeType, durationSeconds } so callers can
 * upload it right away.
 *  - onSegment(result): a long recording reached the size cap and was split; this is a finished segment. Recording continues.
 *  - onAutoStop(result): the recording ended by itself (microphone unplugged, call interruption, recorder error). Nothing is lost:
 *    the audio captured so far is handed over so it can be uploaded.
 */
export default function useAudioRecorder({ onSegment, onAutoStop } = {}) {
  const [isRecording, setIsRecording] = useState(false);
  const [isPaused, setIsPaused] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const [error, setError] = useState(null);
  const [stream, setStream] = useState(null); // the live microphone stream (for a level meter); null when not recording
  const [deviceLabel, setDeviceLabel] = useState('');

  const recorderRef = useRef(null);
  const streamRef = useRef(null);
  const chunksRef = useRef([]);
  const bytesRef = useRef(0);
  const timerRef = useRef(null);
  const timeRef = useRef(0);
  const segmentStartRef = useRef(0);
  const rotateRef = useRef(false);
  const stopResolverRef = useRef(null);
  const startingRef = useRef(false);
  const unmountedRef = useRef(false);
  const handlersRef = useRef({});
  handlersRef.current = { onSegment, onAutoStop };

  const clearTimer = () => {
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = null;
  };
  const startTimer = () => {
    clearTimer();
    timerRef.current = setInterval(() => {
      timeRef.current += 1;
      setRecordingTime(timeRef.current);
    }, 1000);
  };

  const releaseStream = () => {
    streamRef.current?.getTracks().forEach((t) => { t.onended = null; t.stop(); });
    streamRef.current = null;
    if (!unmountedRef.current) setStream(null);
  };

  // One MediaRecorder per segment, all on the same microphone stream.
  const beginSegment = (mediaStream, mimeType) => {
    const recorder = new MediaRecorder(mediaStream, { ...(mimeType ? { mimeType } : {}), audioBitsPerSecond: AUDIO_BITS_PER_SECOND });
    chunksRef.current = [];
    bytesRef.current = 0;
    segmentStartRef.current = timeRef.current;

    recorder.ondataavailable = (e) => {
      if (e.data.size === 0) return;
      chunksRef.current.push(e.data);
      bytesRef.current += e.data.size;
      if (bytesRef.current >= MAX_SEGMENT_BYTES && recorder.state !== 'inactive' && !rotateRef.current) {
        rotateRef.current = true;
        recorder.stop(); // onstop below hands this segment over and starts the next one
      }
    };
    recorder.onerror = () => {
      setError('The recording was interrupted. What was captured has been kept.');
      if (recorder.state !== 'inactive') recorder.stop();
    };
    recorder.onstop = () => {
      const type = recorder.mimeType || mimeType || 'audio/webm';
      const blob = new Blob(chunksRef.current, { type });
      const result = { blob, mimeType: type, durationSeconds: Math.max(0, timeRef.current - segmentStartRef.current) };
      if (rotateRef.current && streamRef.current && !unmountedRef.current) {
        rotateRef.current = false;
        handlersRef.current.onSegment?.(result);
        recorderRef.current = beginSegment(streamRef.current, type);
        recorderRef.current.start(1000);
        return;
      }
      rotateRef.current = false;
      releaseStream();
      clearTimer();
      setIsRecording(false);
      setIsPaused(false);
      if (stopResolverRef.current) {
        stopResolverRef.current(result);
        stopResolverRef.current = null;
      } else if (blob.size > 0 && !unmountedRef.current) {
        handlersRef.current.onAutoStop?.(result); // stopped by itself: keep the audio
      }
    };
    return recorder;
  };

  const startRecording = useCallback(async () => {
    setError(null);
    if (!window.isSecureContext) {
      // Phones block the microphone on plain http:// pages (localhost is exempt).
      setError('Recording needs a secure (https) connection. Open this page using the https:// address.');
      return false;
    }
    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
      setError('This browser does not support audio recording.');
      return false;
    }
    try {
      const mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true },
      });
      // The page was left while the permission prompt was open: don't leave the microphone on.
      if (unmountedRef.current) { mediaStream.getTracks().forEach((t) => t.stop()); return false; }
      streamRef.current = mediaStream;
      setStream(mediaStream);
      const track = mediaStream.getAudioTracks()[0];
      setDeviceLabel(track?.label || '');
      // Microphone unplugged / taken over: the recorder is stopped and the audio so far goes to onAutoStop.
      if (track) track.onended = () => { if (recorderRef.current && recorderRef.current.state !== 'inactive') recorderRef.current.stop(); };
      timeRef.current = 0;
      setRecordingTime(0);
      rotateRef.current = false;
      const mimeType = pickRecordingMimeType();
      const recorder = beginSegment(mediaStream, mimeType);
      recorderRef.current = recorder;
      recorder.start(1000);
      setIsRecording(true);
      setIsPaused(false);
      startTimer();
      return true;
    } catch (e) {
      releaseStream();
      setError(e.name === 'NotAllowedError'
        ? 'Microphone permission was denied. Allow microphone access and try again.'
        : 'Could not start recording. Check that a microphone is connected.');
      return false;
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const start = useCallback(async () => {
    if (startingRef.current || recorderRef.current?.state === 'recording') return false;
    startingRef.current = true;
    try {
      return await startRecording();
    } finally {
      startingRef.current = false;
    }
  }, [startRecording]);

  const pause = useCallback(() => {
    if (recorderRef.current?.state === 'recording') {
      recorderRef.current.pause();
      clearTimer();
      setIsPaused(true);
    }
  }, []);

  const resume = useCallback(() => {
    if (recorderRef.current?.state === 'paused') {
      recorderRef.current.resume();
      startTimer();
      setIsPaused(false);
    }
  }, []);

  const stop = useCallback(() => new Promise((resolve) => {
    const recorder = recorderRef.current;
    if (!recorder || recorder.state === 'inactive') {
      resolve(null);
      return;
    }
    stopResolverRef.current = resolve;
    recorder.stop();
  }), []);

  // Release the microphone if the page is left mid-recording.
  useEffect(() => {
    unmountedRef.current = false;
    return () => {
      unmountedRef.current = true;
      clearTimer();
      if (recorderRef.current && recorderRef.current.state !== 'inactive') {
        recorderRef.current.onstop = null;
        recorderRef.current.stop();
      }
      releaseStream();
    };
  }, []);

  return { isRecording, isPaused, recordingTime, error, start, pause, resume, stop, stream, deviceLabel };
}
