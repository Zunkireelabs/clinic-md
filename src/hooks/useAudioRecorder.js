import { useState, useRef, useCallback, useEffect } from 'react';

// Safari has no webm support, so pick the first format the browser can record.
const PREFERRED_TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];

export const pickRecordingMimeType = (isSupported = (t) => window.MediaRecorder?.isTypeSupported?.(t)) =>
  PREFERRED_TYPES.find((t) => isSupported(t)) || '';

/**
 * Microphone recording with pause/resume. `stop()` resolves with the finished
 * { blob, mimeType, durationSeconds } so callers can upload it right away.
 */
export default function useAudioRecorder() {
  const [isRecording, setIsRecording] = useState(false);
  const [isPaused, setIsPaused] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const [error, setError] = useState(null);

  const recorderRef = useRef(null);
  const streamRef = useRef(null);
  const chunksRef = useRef([]);
  const timerRef = useRef(null);
  const timeRef = useRef(0);
  const stopResolverRef = useRef(null);
  const startingRef = useRef(false);

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
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
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
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true },
      });
      streamRef.current = stream;
      const mimeType = pickRecordingMimeType();
      const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
      chunksRef.current = [];
      timeRef.current = 0;
      setRecordingTime(0);

      recorder.ondataavailable = (e) => { if (e.data.size > 0) chunksRef.current.push(e.data); };
      recorder.onstop = () => {
        const type = recorder.mimeType || mimeType || 'audio/webm';
        const blob = new Blob(chunksRef.current, { type });
        releaseStream();
        clearTimer();
        setIsRecording(false);
        setIsPaused(false);
        stopResolverRef.current?.({ blob, mimeType: type, durationSeconds: timeRef.current });
        stopResolverRef.current = null;
      };

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
  useEffect(() => () => {
    clearTimer();
    if (recorderRef.current && recorderRef.current.state !== 'inactive') {
      recorderRef.current.onstop = null;
      recorderRef.current.stop();
    }
    releaseStream();
  }, []);

  return { isRecording, isPaused, recordingTime, error, start, pause, resume, stop };
}
